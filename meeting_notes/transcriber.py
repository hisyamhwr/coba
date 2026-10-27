"""Transkripsi audio secara lokal dengan faster-whisper."""

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

# Membantu Whisper mengenali percakapan campuran Indonesia-Inggris.
INITIAL_PROMPT = (
    "Ini adalah rekaman rapat kerja dalam Bahasa Indonesia yang bercampur dengan istilah English, "
    "misalnya deadline, meeting, follow up, project, dan budget."
)


@dataclass
class Segment:
    start: float
    end: float
    text: str


def format_timestamp(seconds: float) -> str:
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def segments_to_text(segments: list[Segment]) -> str:
    return "\n".join(f"[{format_timestamp(s.start)}] {s.text}" for s in segments)


class Transcriber:
    def __init__(self, model_size: str = "small", language: str | None = "id"):
        self.model_size = model_size
        self.language = language
        self._model = None

    def _load(self):
        if self._model is None:
            from faster_whisper import WhisperModel

            # Model diunduh sekali saat pertama dipakai, setelah itu berjalan offline.
            self._model = WhisperModel(self.model_size, device="auto", compute_type="int8")
        return self._model

    def transcribe(self, audio_path: Path, on_progress: Callable[[float], None] | None = None) -> list[Segment]:
        segments, info = self._load().transcribe(
            str(audio_path),
            language=self.language,
            initial_prompt=INITIAL_PROMPT,
            vad_filter=True,
            beam_size=5,
        )
        result = []
        for seg in segments:
            text = seg.text.strip()
            if text:
                result.append(Segment(seg.start, seg.end, text))
            if on_progress and info.duration:
                on_progress(min(seg.end / info.duration, 1.0))
        return result
