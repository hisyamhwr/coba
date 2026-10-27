"""Merangkum transkrip rapat dalam Bahasa Indonesia menggunakan Claude.

Dua cara tersedia:
- ClaudeCodeSummarizer: lewat Claude Code CLI, memakai kuota langganan Claude Pro/Max (tanpa API key).
- Summarizer: lewat Claude API, ditagih per pemakaian dengan ANTHROPIC_API_KEY.
"""

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import anthropic
from pydantic import BaseModel, Field

from .config import Settings

SYSTEM_PROMPT = """\
Kamu adalah notulen rapat yang teliti. Kamu menerima transkrip otomatis sebuah rapat yang \
bahasanya campuran Indonesia dan Inggris. Transkrip bisa mengandung salah dengar, jadi pahami \
maksudnya dari konteks.

Tulis seluruh hasil dalam Bahasa Indonesia yang jelas dan ringkas. Istilah teknis atau nama \
produk berbahasa Inggris boleh dipertahankan. Jangan mengarang informasi yang tidak ada di \
transkrip: jika penanggung jawab atau tenggat tidak disebutkan, isi dengan "-".\
"""


class ActionItem(BaseModel):
    task: str = Field(description="Tugas yang harus dikerjakan")
    owner: str = Field(description="Penanggung jawab, atau '-' jika tidak disebutkan")
    deadline: str = Field(description="Tenggat waktu, atau '-' jika tidak disebutkan")


class MeetingSummary(BaseModel):
    title: str = Field(description="Judul singkat rapat berdasarkan topik utamanya")
    summary: str = Field(description="Ringkasan rapat dalam 1-2 paragraf")
    participants: list[str] = Field(description="Nama peserta yang disebut di transkrip")
    key_points: list[str] = Field(description="Poin-poin utama yang dibahas")
    decisions: list[str] = Field(description="Keputusan yang disepakati")
    action_items: list[ActionItem] = Field(description="Tindak lanjut")
    open_questions: list[str] = Field(description="Pertanyaan atau isu yang belum terjawab")


class Summarizer:
    def __init__(self, model: str = "claude-opus-5-5"):
        self.model = model
        self.client = anthropic.Anthropic()

    def summarize(self, transcript: str) -> MeetingSummary:
        response = self.client.beta.messages.parse(
            model=self.model,
            max_tokens=16000,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": _wrap_transcript(transcript)}],
            output_format=MeetingSummary,
            output_config={"effort": "medium"},
            # Jika permintaan ditolak oleh safety classifier, API otomatis mencoba model cadangan.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        if response.stop_reason == "refusal":
            raise RuntimeError("Claude menolak merangkum transkrip ini.")
        if response.parsed_output is None:
            raise RuntimeError(f"Ringkasan tidak lengkap (stop_reason={response.stop_reason}).")
        return response.parsed_output


def _wrap_transcript(transcript: str) -> str:
    return f"<transkrip>\n{transcript}\n</transkrip>"


class ClaudeCodeSummarizer:
    def __init__(self, executable: str, model: str | None = None, timeout: int = 900):
        self.executable = executable
        self.model = model
        self.timeout = timeout

    def summarize(self, transcript: str) -> MeetingSummary:
        cmd = [
            self.executable, "-p", "Buat notulen dari transkrip rapat yang diberikan.",
            "--output-format", "json",
            "--json-schema", json.dumps(MeetingSummary.model_json_schema()),
            "--system-prompt", SYSTEM_PROMPT,
            "--tools", "",
            "--no-session-persistence",
        ]
        if self.model:
            cmd += ["--model", self.model]
        # Tanpa API key di environment, Claude Code memakai login langganan (claude.ai).
        env = {k: v for k, v in os.environ.items() if k not in {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"}}
        proc = subprocess.run(
            cmd, input=_wrap_transcript(transcript), capture_output=True, text=True,
            timeout=self.timeout, env=env, cwd=tempfile.gettempdir(),
        )
        try:
            data = json.loads(proc.stdout)
        except json.JSONDecodeError:
            raise RuntimeError((proc.stderr or proc.stdout).strip()[-300:] or "Claude Code gagal") from None
        if data.get("is_error") or not data.get("structured_output"):
            raise RuntimeError(f"Claude Code: {data.get('result') or data.get('subtype')}")
        return MeetingSummary.model_validate(data["structured_output"])


def find_claude_cli() -> str | None:
    candidates = [Path.home() / ".claude" / "local" / "claude", Path.home() / ".local" / "bin" / "claude"]
    return shutil.which("claude") or next((str(p) for p in candidates if p.exists()), None)


def make_summarizer(settings: Settings) -> tuple[Summarizer | ClaudeCodeSummarizer | None, str | None]:
    """Pilih cara merangkum. Mengembalikan (summarizer, None) atau (None, alasan tidak tersedia)."""
    mode = settings.summarizer
    has_api_key = bool(os.getenv("ANTHROPIC_API_KEY") or os.getenv("ANTHROPIC_AUTH_TOKEN"))
    if mode == "none":
        return None, "Ringkasan dimatikan (SUMMARIZER=none)."
    if mode == "api" or (mode == "auto" and has_api_key):
        if not has_api_key:
            return None, "ANTHROPIC_API_KEY belum diatur, jadi hanya transkrip yang disimpan."
        return Summarizer(settings.claude_model), None
    cli = find_claude_cli()
    if cli:
        return ClaudeCodeSummarizer(cli, settings.claude_code_model), None
    return None, (
        "Claude Code belum terpasang, jadi hanya transkrip yang disimpan. "
        "Pasang Claude Code dan login dengan akun Claude Pro untuk ringkasan otomatis."
    )
