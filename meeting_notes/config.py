"""Pengaturan aplikasi, dibaca dari environment variable atau file .env."""

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "ya", "on"}


@dataclass
class Settings:
    # Whisper: tiny, base, small, medium, large-v3. "small" seimbang antara akurasi dan kecepatan di CPU.
    whisper_model: str = field(default_factory=lambda: os.getenv("WHISPER_MODEL", "small"))
    # Bahasa utama rapat. "id" tetap menangkap istilah Inggris dengan baik; "auto" untuk deteksi otomatis.
    language: str | None = field(
        default_factory=lambda: None
        if os.getenv("MEETING_LANGUAGE", "id") == "auto"
        else os.getenv("MEETING_LANGUAGE", "id")
    )
    claude_model: str = field(default_factory=lambda: os.getenv("CLAUDE_MODEL", "claude-opus-5-5"))
    output_dir: Path = field(
        default_factory=lambda: Path(os.getenv("OUTPUT_DIR", "~/MeetingNotes")).expanduser()
    )
    # Rekam juga suara dari speaker/headphone (peserta meeting online). Windows & Linux saja.
    capture_system_audio: bool = field(default_factory=lambda: _env_bool("CAPTURE_SYSTEM_AUDIO", True))
    sample_rate: int = 16000
