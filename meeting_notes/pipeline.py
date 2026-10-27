"""Alur lengkap: audio -> transkrip -> ringkasan -> file .md dan .docx."""

import os
import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import soundfile as sf

from .config import Settings
from .exporter import MeetingInfo, render_markdown, write_docx
from .summarizer import Summarizer
from .transcriber import Transcriber, segments_to_text


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
    info = MeetingInfo(started_at=started_at, duration_seconds=sf.info(str(audio_path)).duration)

    on_status("Mentranskrip audio (lokal)...")
    transcriber = transcriber or Transcriber(settings.whisper_model, settings.language)
    segments = transcriber.transcribe(audio_path, lambda p: on_status(f"Mentranskrip... {p:.0%}"))

    summary, note = None, None
    if not segments:
        note = "Tidak ada suara yang terdeteksi dalam rekaman."
    elif not (os.getenv("ANTHROPIC_API_KEY") or os.getenv("ANTHROPIC_AUTH_TOKEN")):
        note = "ANTHROPIC_API_KEY belum diatur, jadi hanya transkrip yang disimpan (tanpa ringkasan)."
    else:
        on_status("Membuat ringkasan...")
        try:
            summary = Summarizer(settings.claude_model).summarize(segments_to_text(segments))
        except Exception as exc:  # noqa: BLE001 - transkrip tetap disimpan walau ringkasan gagal
            note = f"Ringkasan gagal dibuat ({exc}). Transkrip tetap disimpan."

    settings.output_dir.mkdir(parents=True, exist_ok=True)
    base = f"{started_at:%Y-%m-%d_%H%M}_{_slug(summary.title if summary else 'rapat')}"
    md_path = settings.output_dir / f"{base}.md"
    md_path.write_text(render_markdown(info, segments, summary, note), encoding="utf-8")
    docx_path = write_docx(settings.output_dir / f"{base}.docx", info, segments, summary, note)

    on_status("Selesai!")
    return NotesResult(md_path, docx_path, note)
