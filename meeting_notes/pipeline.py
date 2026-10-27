"""Alur lengkap: audio -> transkrip -> koreksi & ringkasan -> file .md dan .docx."""

import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .config import Settings
from .exporter import MeetingInfo, render_markdown, write_docx
from .glossary import Glossary, apply_corrections
from .summarizer import make_summarizer
from .transcriber import SAMPLE_RATE, Segment, Transcriber, load_audio, segments_to_text, to_paragraphs


@dataclass
class NotesResult:
    markdown_path: Path
    docx_path: Path
    note: str | None


def _slug(text: str) -> str:
    return re.sub(r"[^\w]+", "-", text.lower()).strip("-")[:50] or "rapat"


def process_recording(
    audio_path: Path,
    settings: Settings,
    started_at: datetime | None = None,
    on_status: Callable[[str], None] = print,
    transcriber: Transcriber | None = None,
) -> NotesResult:
    started_at = started_at or datetime.now()
    glossary = Glossary(settings.glossary_path)
    audio = load_audio(audio_path)
    info = MeetingInfo(started_at=started_at, duration_seconds=len(audio) / SAMPLE_RATE)

    on_status("Mentranskrip audio (lokal)...")
    transcriber = transcriber or Transcriber(settings.whisper_model, settings.language, settings.whisper_engine)
    transcriber.vocabulary = glossary.whisper_hint()
    segments = transcriber.transcribe(audio, lambda p: on_status(f"Mentranskrip... {p:.0%}"))
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
            summary = summarizer.summarize(segments_to_text(paragraphs), glossary.terms)
        except Exception as exc:  # noqa: BLE001 - transkrip tetap disimpan walau ringkasan gagal
            note = f"Ringkasan gagal dibuat ({exc}). Transkrip tetap disimpan."

    if summary:
        pairs = [(c.wrong, c.correct) for c in summary.corrections]
        fixed = []
        for p in paragraphs:
            text, counts = apply_corrections(p.text, pairs)
            fixed.append(Segment(p.start, p.end, text))
            for key, n in counts.items():
                corrections[key] = corrections.get(key, 0) + n
        paragraphs = fixed
        glossary.merge(summary.glossary_terms)
        glossary.save()

    settings.output_dir.mkdir(parents=True, exist_ok=True)
    base = f"{started_at:%Y-%m-%d_%H%M}_{_slug(summary.title if summary else 'rapat')}"
    md_path = settings.output_dir / f"{base}.md"
    md_path.write_text(render_markdown(info, paragraphs, summary, note, corrections), encoding="utf-8")
    docx_path = write_docx(settings.output_dir / f"{base}.docx", info, paragraphs, summary, note, corrections)

    on_status("Selesai!")
    return NotesResult(md_path, docx_path, note)
