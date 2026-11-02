"""Alur lengkap: audio -> transkrip -> koreksi & ringkasan -> file .md (dan .docx bila diminta)."""

import re
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

from .cloud_stt import PROVIDERS, transcribe_with_fallback
from .config import ACCURATE_MODEL, Settings
from .exporter import MeetingInfo, render_markdown, write_docx
from .glossary import Glossary, apply_corrections
from .summarizer import make_summarizer
from .transcriber import (
    MIC_LABEL,
    SAMPLE_RATE,
    SPEECH_LEVEL,
    SYSTEM_LABEL,
    Segment,
    Transcriber,
    clean_segments,
    label_speakers,
    load_audio,
    merge_tracks,
    segments_to_text,
    speech_level,
    to_paragraphs,
)

# Aplikasi Mac menyimpan jalur terpisah di samping meeting.wav (campuran).
MIC_TRACK = "mic.wav"
SYSTEM_TRACK = "sistem.wav"


@dataclass
class NotesResult:
    markdown_path: Path
    docx_path: Path | None
    note: str | None
    title: str = ""
    decisions: int = 0
    action_items: int = 0


def _slug(text: str) -> str:
    return re.sub(r"[^\w]+", "-", text.lower()).strip("-")[:50] or "rapat"


def load_tracks(audio_path: Path) -> tuple[np.ndarray, np.ndarray] | None:
    """Jalur meeting dan mic dari aplikasi Mac, bila keduanya ada."""
    system, mic = audio_path.with_name(SYSTEM_TRACK), audio_path.with_name(MIC_TRACK)
    if not (system.exists() and mic.exists()):
        return None
    return load_audio(system), load_audio(mic)


def transcribe(
    audio: np.ndarray, settings: Settings, glossary: Glossary, transcriber: Transcriber | None,
    on_status: Callable[[str], None], tracks: tuple[np.ndarray, np.ndarray] | None = None,
) -> tuple[list[Segment], str | None]:
    """Transkripsi dengan mesin pilihan; jika mesin cloud tidak tersedia/gagal, kembali ke Whisper lokal.

    tracks: (jalur meeting, jalur mic). Bila keduanya berisi ucapan, Whisper lokal mentranskripsi masing-masing
    jalur terpisah: suara meeting yang digital tidak tercampur derau ruangan dari mic, suara sendiri yang pelan
    dikuatkan tersendiri, dan transkrip berlabel "Saya (mic)" / "Peserta online".
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
                    sf.write(path, audio, SAMPLE_RATE, format="FLAC")
                    segments = transcribe_with_fallback(provider, path, glossary.all_terms)
                    return label_speakers(clean_segments(segments)), None
            except Exception as exc:  # noqa: BLE001 - rapat tetap tercatat dengan Whisper lokal
                note = f"{provider.name} gagal ({str(exc)[:150]}), memakai Whisper lokal."

    if settings.whisper_model == ACCURATE_MODEL:
        on_status("Mentranskrip mode akurat (pertama kali mengunduh model +-3 GB)...")
    else:
        on_status("Mentranskrip audio (lokal)...")
    transcriber = transcriber or Transcriber(settings.whisper_model, settings.language, settings.whisper_engine)
    transcriber.vocabulary = glossary.whisper_hint()
    if tracks and all(speech_level(track) >= SPEECH_LEVEL for track in tracks):
        system, mic = tracks
        system_segments = transcriber.transcribe(
            system, lambda p: on_status(f"Mentranskrip suara meeting... {p / 2:.0%}"))
        mic_segments = transcriber.transcribe(
            mic, lambda p: on_status(f"Mentranskrip suaramu (mic)... {0.5 + p / 2:.0%}"))
        return merge_tracks(
            [Segment(s.start, s.end, s.text, SYSTEM_LABEL) for s in system_segments],
            [Segment(s.start, s.end, s.text, MIC_LABEL) for s in mic_segments],
        ), note
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
    audio = load_audio(audio_path)
    info = MeetingInfo(started_at=started_at, duration_seconds=len(audio) / SAMPLE_RATE)

    segments, engine_note = transcribe(audio, settings, glossary, transcriber, on_status, load_tracks(audio_path))
    paragraphs = to_paragraphs(segments)

    summary, note, corrections = None, None, {}
    summarizer, unavailable_reason = make_summarizer(settings) if segments else (None, None)
    if not segments:
        note = "Tidak ada suara yang terdeteksi dalam rekaman."
    elif summarizer is None:
        note = unavailable_reason
    else:
        on_status("Mengoreksi transkrip & menyusun MoM...")
        try:
            summary = summarizer.summarize(segments_to_text(paragraphs), glossary.all_terms, list(marks))
        except Exception as exc:  # noqa: BLE001 - transkrip tetap disimpan walau ringkasan gagal
            note = f"Ringkasan gagal dibuat ({exc}). Transkrip tetap disimpan."

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
        return NotesResult(md_path, docx_path, note, summary.title, len(summary.decisions), len(summary.action_items))
    return NotesResult(md_path, docx_path, note, _title_fallback(started_at))


def _title_fallback(started_at: datetime) -> str:
    return f"Rapat {started_at:%d-%m-%Y}"
