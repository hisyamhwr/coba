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
    # Whisper: auto, tiny, base, small, medium, large-v3, large-v3-turbo.
    # "auto": large-v3 (paling akurat untuk bicara cepat) di Mac Apple Silicon dengan RAM >= 16 GB, selain itu
    # large-v3-turbo (+-1,6 GB, cocok untuk RAM 8 GB). Lihat transcriber.resolve_model.
    whisper_model: str = field(default_factory=lambda: os.getenv("WHISPER_MODEL") or "auto")
    # Mesin transkripsi: lokal (Whisper di laptop, gratis) atau cloud: elevenlabs, assemblyai, deepgram.
    # Mesin cloud butuh API key-nya di .env; jika gagal, otomatis kembali ke Whisper lokal.
    transcription_engine: str = field(
        default_factory=lambda: os.getenv("TRANSCRIPTION_ENGINE", "lokal").strip().lower()
    )
    # auto: mlx-whisper di Mac Apple Silicon, faster-whisper di perangkat lain. Pilihan: mlx, faster-whisper.
    whisper_engine: str = field(default_factory=lambda: os.getenv("WHISPER_ENGINE", "auto").strip().lower())
    # Bahasa utama rapat. "id" tetap menangkap istilah Inggris dengan baik; "auto" untuk deteksi otomatis.
    language: str | None = field(
        default_factory=lambda: None
        if os.getenv("MEETING_LANGUAGE", "id") == "auto"
        else os.getenv("MEETING_LANGUAGE", "id")
    )
    # auto: pakai Claude API jika ANTHROPIC_API_KEY ada, selain itu Claude Code (langganan Pro/Max).
    # Pilihan lain: api, claude-code, none.
    summarizer: str = field(default_factory=lambda: os.getenv("SUMMARIZER", "auto").strip().lower())
    claude_model: str = field(default_factory=lambda: os.getenv("CLAUDE_MODEL", "claude-opus-5-5"))
    # Model untuk mode Claude Code, mis. "sonnet" atau "opus". Kosong = default akunmu.
    # Sonnet dengan effort medium: diuji pada transkrip 1 jam, MoM jadi dalam +-25 detik (pengaturan bawaan
    # Claude Code +-4 menit) dengan agenda, action item, dan koreksi istilah yang sama lengkapnya.
    claude_code_model: str = field(default_factory=lambda: os.getenv("CLAUDE_CODE_MODEL") or "sonnet")
    claude_code_effort: str = field(
        default_factory=lambda: os.getenv("CLAUDE_CODE_EFFORT") or "medium")
    output_dir: Path = field(
        default_factory=lambda: Path(os.getenv("OUTPUT_DIR", "~/MeetingNotes")).expanduser()
    )
    # Rekam juga suara dari speaker/headphone (peserta meeting online). Windows & Linux saja.
    capture_system_audio: bool = field(default_factory=lambda: _env_bool("CAPTURE_SYSTEM_AUDIO", True))
    # Buat juga file Word (.docx) selain Markdown (.md). Bisa diubah lewat centang di widget/aplikasi Mac.
    export_docx: bool = field(default_factory=lambda: _env_bool("EXPORT_DOCX", False))
    sample_rate: int = 16000

    @property
    def glossary_path(self) -> Path:
        return self.output_dir / "kamus.txt"
