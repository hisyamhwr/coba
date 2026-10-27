"""Merangkum transkrip rapat dalam Bahasa Indonesia menggunakan Claude."""

import anthropic
from pydantic import BaseModel, Field

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
            messages=[{"role": "user", "content": f"<transkrip>\n{transcript}\n</transkrip>"}],
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
