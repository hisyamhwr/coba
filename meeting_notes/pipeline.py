"""Alur lengkap: audio -> transkrip -> koreksi & ringkasan -> file .md (dan .docx bila diminta)."""

import json
import re
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

from .cloud_stt import PROVIDERS, transcribe_with_fallback
from .config import Settings
from .exporter import MeetingInfo, render_markdown, write_docx
from .glossary import Glossary, apply_corrections
from .incremental import TRACKS, load_state, track_segments
from .wavio import GrowingWav, is_pcm_wav
from .summarizer import make_summarizer
from .transcriber import (
    ACCURATE_MODEL,
    FAST_MODEL,
    MIC_LABEL,
    SAMPLE_RATE,
    SYSTEM_LABEL,
    Segment,
    Transcriber,
    clean_segments,
    label_speakers,
    load_audio,
    merge_tracks,
    segments_to_text,
    to_paragraphs,
)

# Sisa audio (semua jalur) yang belum ditranskripsi di latar belakang. Bila lebih dari ini (mis. proses ulang
# rekaman lama), pakai turbo agar MoM tetap cepat jadi.
MAX_ACCURATE_BACKLOG_SECONDS = 600
# Transkrip akhir rekaman aplikasi Mac disimpan di folder rekaman, sehingga "Proses ulang" (mis. setelah MoM
# gagal karena batas pemakaian Claude) langsung menyusun MoM tanpa mentranskripsi ulang.
TRANSCRIPT_CACHE = "transkrip_final.json"
# Jeda sebelum mencoba sekali lagi bila Claude gagal (jaringan putus sesaat, server sibuk).
SUMMARY_RETRY_DELAY = 10.0


@dataclass
class NotesResult:
    markdown_path: Path
    docx_path: Path | None
    note: str | None
    title: str = ""
    decisions: int = 0
    action_items: int = 0
    summarized: bool = False


def _slug(text: str) -> str:
    return re.sub(r"[^\w]+", "-", text.lower()).strip("-")[:50] or "rapat"


def read_audio(path: Path) -> np.ndarray:
    """Rekaman aplikasi Mac dibaca langsung (tahan header rusak); file lain lewat dekoder audio."""
    return GrowingWav(path).read() if is_pcm_wav(path) else load_audio(path)


def audio_seconds(path: Path) -> float:
    if is_pcm_wav(path):
        return GrowingWav(path).samples() / SAMPLE_RATE
    return len(load_audio(path)) / SAMPLE_RATE


def load_transcript(path: Path | None) -> tuple[list[Segment], str | None] | None:
    if path is None or not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        segments = [Segment(float(a), float(b), str(t), sp) for a, b, t, sp in data["segments"]]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return segments, data.get("note")


def save_transcript(path: Path | None, segments: list[Segment], note: str | None) -> None:
    if path is None:
        return
    data = {"segments": [[s.start, s.end, s.text, s.speaker] for s in segments], "note": note}
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def transcribe_tracks(folder: Path, transcriber: Transcriber, on_status: Callable[[str], None]) -> list[Segment] | None:
    """Transkripsi jalur meeting dan mic dari aplikasi Mac, melanjutkan hasil transkripsi latar belakang.

    Tiap jalur ditranskripsi terpisah: suara meeting yang digital tidak tercampur derau ruangan dari mic, suara
    sendiri yang pelan dikuatkan tersendiri, dan transkrip berlabel "Saya (mic)" / "Peserta online".
    """
    paths = {name: folder / file for name, file in TRACKS.items()}
    if not all(path.exists() for path in paths.values()):
        return None
    state = load_state(folder)
    readers = {name: GrowingWav(path) for name, path in paths.items()}
    progress_from = {name: track_segments(state, name)[0] for name in paths}
    remaining = {name: max(0, readers[name].samples() - int(until * SAMPLE_RATE)) / SAMPLE_RATE
                 for name, until in progress_from.items()}
    backlog = sum(remaining.values())
    if backlog > MAX_ACCURATE_BACKLOG_SECONDS and transcriber.model_size == ACCURATE_MODEL:
        transcriber.use_model(FAST_MODEL)
    total, done, results = max(backlog, 1.0), 0.0, {}
    for name, reader in readers.items():
        until, segments = track_segments(state, name)
        label = "suara meeting" if name == "sistem" else "suaramu (mic)"
        seconds = remaining[name]

        def progress(p: float, label=label, base=done, seconds=seconds) -> None:
            on_status(f"Mentranskrip {label}... {(base + p * seconds) / total:.0%}")

        new = []
        if seconds >= 1:
            # Satu jalur dibaca pada satu waktu, dan hanya sisa yang belum ditranskripsi di latar belakang
            # (hemat memori untuk rapat panjang).
            new = transcriber.transcribe_wav(reader, int(until * SAMPLE_RATE), progress)
        done += seconds
        results[name] = clean_segments(segments + new)
    system, mic = results["sistem"], results["mic"]
    if system and mic:
        return merge_tracks(
            [Segment(s.start, s.end, s.text, SYSTEM_LABEL) for s in system],
            [Segment(s.start, s.end, s.text, MIC_LABEL) for s in mic],
        )
    # Hanya satu jalur bersuara (mis. rapat offline: hanya mic): tanpa label.
    return system or mic


def transcribe(
    load: Callable[[], np.ndarray], settings: Settings, glossary: Glossary, transcriber: Transcriber | None,
    on_status: Callable[[str], None], folder: Path | None = None,
) -> tuple[list[Segment], str | None]:
    """Transkripsi dengan mesin pilihan; jika mesin cloud tidak tersedia/gagal, kembali ke Whisper lokal.

    load: membaca audio campuran, dipanggil hanya bila perlu (mesin cloud, atau rekaman tanpa jalur terpisah).
    folder: folder rekaman aplikasi Mac; bila berisi jalur terpisah, Whisper lokal memakai transcribe_tracks.
    """
    note = None
    engine = settings.transcription_engine
    if engine != "lokal":
        provider = PROVIDERS[engine]() if engine in PROVIDERS else None
        if provider is None:
            note = f"TRANSCRIPTION_ENGINE '{engine}' tidak dikenal, memakai Whisper lokal."
        elif not provider.api_key:
            note = f"{provider.env_key} belum diisi, memakai Whisper lokal."
        else:
            on_status(f"Mentranskrip via {provider.name}...")
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    # FLAC: tanpa kehilangan kualitas tapi ukurannya +-separuh WAV, jadi unggahan lebih cepat.
                    path = Path(tmp) / "rapat.flac"
                    sf.write(path, load(), SAMPLE_RATE, format="FLAC")
                    segments = transcribe_with_fallback(provider, path, glossary.all_terms)
                    return label_speakers(clean_segments(segments)), None
            except Exception as exc:  # noqa: BLE001 - rapat tetap tercatat dengan Whisper lokal
                note = f"{provider.name} gagal ({str(exc)[:150]}), memakai Whisper lokal."

    on_status("Mentranskrip audio (lokal)...")
    transcriber = transcriber or Transcriber(settings.whisper_model, settings.language, settings.whisper_engine)
    transcriber.vocabulary = glossary.whisper_hint()
    if folder is not None:
        segments = transcribe_tracks(folder, transcriber, on_status)
        if segments is not None:
            return segments, note
    audio = load()
    if len(audio) / SAMPLE_RATE > MAX_ACCURATE_BACKLOG_SECONDS and transcriber.model_size == ACCURATE_MODEL:
        transcriber.use_model(FAST_MODEL)
    return transcriber.transcribe(audio, lambda p: on_status(f"Mentranskrip... {p:.0%}")), note


def process_recording(
    audio_path: Path,
    settings: Settings,
    started_at: datetime | None = None,
    on_status: Callable[[str], None] = print,
    transcriber: Transcriber | None = None,
    marks: list[float] = (),
) -> NotesResult:
    """marks: detik-detik saat pengguna menekan "Tandai penting" (dari aplikasi Mac)."""
    started_at = started_at or datetime.now()
    glossary = Glossary(settings.glossary_path)
    folder = audio_path.parent
    mac_recording = all((folder / file).exists() for file in TRACKS.values())
    info = MeetingInfo(started_at=started_at, duration_seconds=audio_seconds(audio_path))

    cache = folder / TRANSCRIPT_CACHE if mac_recording else None
    cached = load_transcript(cache)
    if cached is not None:
        on_status("Mentranskrip... 100% (memakai transkrip yang sudah ada)")
        segments, engine_note = cached
    else:
        segments, engine_note = transcribe(
            lambda: read_audio(audio_path), settings, glossary, transcriber, on_status, folder)
        save_transcript(cache, segments, engine_note)
    paragraphs = to_paragraphs(segments)

    summary, note, corrections = None, None, {}
    summarizer, unavailable_reason = make_summarizer(settings) if segments else (None, None)
    if not segments:
        note = "Tidak ada suara yang terdeteksi dalam rekaman."
    elif summarizer is None:
        note = unavailable_reason
    else:
        on_status("Mengoreksi transkrip & menyusun MoM...")
        transcript = segments_to_text(paragraphs)
        for attempt in (1, 2):
            try:
                summary = summarizer.summarize(transcript, glossary.all_terms, list(marks))
                break
            except Exception as exc:  # noqa: BLE001 - transkrip tetap disimpan walau ringkasan gagal
                if attempt == 2:
                    note = (f"MoM gagal disusun ({str(exc)[:200]}). Transkrip tetap disimpan; klik Susun ulang "
                            "untuk mencoba lagi tanpa mentranskripsi ulang.")
                else:
                    on_status("Mengoreksi transkrip & menyusun MoM (mencoba lagi)...")
                    time.sleep(SUMMARY_RETRY_DELAY)

    if summary:
        pairs = [(c.wrong, c.correct) for c in summary.corrections]
        fixed = []
        for p in paragraphs:
            text, counts = apply_corrections(p.text, pairs)
            fixed.append(Segment(p.start, p.end, text, p.speaker))
            for key, n in counts.items():
                corrections[key] = corrections.get(key, 0) + n
        paragraphs = fixed
        glossary.merge(summary.glossary_terms)
        glossary.save()

    note = " ".join(n for n in (engine_note, note) if n) or None
    settings.output_dir.mkdir(parents=True, exist_ok=True)
    base = f"{started_at:%Y-%m-%d_%H%M}_{_slug(summary.title if summary else 'rapat')}"
    md_path = settings.output_dir / f"{base}.md"
    md_path.write_text(render_markdown(info, paragraphs, summary, note, corrections), encoding="utf-8")
    docx_path = None
    if settings.export_docx:
        docx_path = write_docx(settings.output_dir / f"{base}.docx", info, paragraphs, summary, note, corrections)

    on_status("Selesai!")
    if summary:
        return NotesResult(md_path, docx_path, note, summary.title, len(summary.decisions), len(summary.action_items),
                           summarized=True)
    return NotesResult(md_path, docx_path, note, _title_fallback(started_at))


def _title_fallback(started_at: datetime) -> str:
    return f"Rapat {started_at:%d-%m-%Y}"
