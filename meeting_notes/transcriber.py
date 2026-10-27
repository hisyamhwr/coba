"""Transkripsi audio secara lokal dengan Whisper.

Di Mac Apple Silicon (M1/M2/...) memakai mlx-whisper yang berjalan di GPU Mac; selain itu faster-whisper.
Audio diproses per potongan +-10 menit agar progres terlihat dan rapat 4 jam tidak membebani memori.
"""

import platform
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
CHUNK_SECONDS = 600
# Potongan dicari di titik paling sunyi dalam 20 detik terakhir agar kalimat tidak terpotong.
CUT_SEARCH_SECONDS = 20
SILENCE_RMS = 1e-3

# Membantu Whisper mengenali percakapan campuran Indonesia-Inggris.
BASE_PROMPT = (
    "Ini adalah rekaman rapat kerja dalam Bahasa Indonesia yang bercampur dengan istilah English, "
    "misalnya deadline, meeting, follow up, project, dan budget."
)

# Kalimat "halusinasi" khas Whisper saat bagian rekaman sunyi.
HALLUCINATIONS = (
    "terima kasih telah menonton",
    "terima kasih sudah menonton",
    "sampai jumpa di video berikutnya",
    "jangan lupa like dan subscribe",
    "thanks for watching",
    "thank you for watching",
    "subtitle by",
    "subtitles by",
)

MLX_REPOS = {
    "tiny": "mlx-community/whisper-tiny",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
}


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


def to_paragraphs(segments: list[Segment], max_gap: float = 2.0, max_chars: int = 700) -> list[Segment]:
    """Gabungkan potongan pendek Whisper menjadi paragraf; jeda panjang memulai paragraf baru."""
    paragraphs: list[Segment] = []
    for seg in segments:
        last = paragraphs[-1] if paragraphs else None
        if last and seg.start - last.end <= max_gap and len(last.text) + len(seg.text) < max_chars:
            paragraphs[-1] = Segment(last.start, seg.end, f"{last.text} {seg.text}")
        else:
            paragraphs.append(Segment(seg.start, seg.end, seg.text))
    return paragraphs


def _normalize(text: str) -> str:
    return re.sub(r"[^\w\s]", "", text.lower()).strip()


def clean_segments(segments: list[Segment]) -> list[Segment]:
    """Buang halusinasi Whisper dan baris yang terulang beruntun."""
    result: list[Segment] = []
    for seg in segments:
        norm = _normalize(seg.text)
        if not norm:
            continue
        if any(h in norm and len(norm) < len(h) + 15 for h in HALLUCINATIONS):
            continue
        if result and _normalize(result[-1].text) == norm:
            continue
        result.append(seg)
    return result


def chunk_bounds(audio: np.ndarray, sr: int = SAMPLE_RATE, chunk_seconds: int = CHUNK_SECONDS,
                 search_seconds: int = CUT_SEARCH_SECONDS) -> list[tuple[int, int]]:
    """Bagi audio menjadi potongan +-chunk_seconds, dipotong di bagian paling sunyi."""
    n, chunk, frame = len(audio), chunk_seconds * sr, sr // 10
    search = min(search_seconds, chunk_seconds // 2) * sr
    starts = [0]
    while n - starts[-1] > chunk:
        target = starts[-1] + chunk
        window = audio[target - search:target]
        energy = (window[: len(window) // frame * frame].reshape(-1, frame) ** 2).mean(axis=1)
        starts.append(target - search + int(energy.argmin()) * frame + frame // 2)
    return list(zip(starts, starts[1:] + [n], strict=True))


def load_audio(path: Path) -> np.ndarray:
    """Baca file audio apa pun (wav, mp3, m4a, ...) menjadi mono 16 kHz."""
    from faster_whisper import decode_audio

    return decode_audio(str(path), sampling_rate=SAMPLE_RATE)


def is_apple_silicon() -> bool:
    return sys.platform == "darwin" and platform.machine() == "arm64"


class _FasterWhisperEngine:
    def __init__(self, model_size: str, language: str | None):
        self.model_size = model_size
        self.language = language
        self._model = None

    def download(self) -> None:
        from faster_whisper import download_model

        download_model(self.model_size)

    def transcribe(self, audio: np.ndarray, prompt: str) -> list[Segment]:
        if self._model is None:
            from faster_whisper import WhisperModel

            self._model = WhisperModel(self.model_size, device="auto", compute_type="int8")
        segments, _ = self._model.transcribe(
            audio, language=self.language, initial_prompt=prompt, vad_filter=True, beam_size=5,
        )
        return [Segment(s.start, s.end, s.text.strip()) for s in segments]


class _MlxEngine:
    def __init__(self, model_size: str, language: str | None):
        self.repo = MLX_REPOS.get(model_size, model_size)
        self.language = language

    def download(self) -> None:
        from huggingface_hub import snapshot_download

        snapshot_download(self.repo)

    def transcribe(self, audio: np.ndarray, prompt: str) -> list[Segment]:
        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio, path_or_hf_repo=self.repo, language=self.language, initial_prompt=prompt,
            # Mencegah Whisper mengulang kalimat yang sama terus-menerus pada rapat panjang.
            condition_on_previous_text=False,
        )
        return [
            Segment(s["start"], s["end"], s["text"].strip())
            for s in result["segments"]
            if not (s.get("no_speech_prob", 0) > 0.6 and s.get("avg_logprob", 0) < -1.0)
        ]


class Transcriber:
    def __init__(
        self, model_size: str = "large-v3-turbo", language: str | None = "id", engine: str = "auto",
        chunk_seconds: int = CHUNK_SECONDS,
    ):
        self.chunk_seconds = chunk_seconds
        use_mlx = engine == "mlx" or (engine == "auto" and is_apple_silicon())
        self.engine = (_MlxEngine if use_mlx else _FasterWhisperEngine)(model_size, language)

    def download(self) -> None:
        """Unduh model (sekali saja) tanpa memuatnya ke memori."""
        self.engine.download()

    def prompt(self) -> str:
        return BASE_PROMPT

    def transcribe(self, audio: np.ndarray, on_progress: Callable[[float], None] | None = None) -> list[Segment]:
        bounds = chunk_bounds(audio, chunk_seconds=self.chunk_seconds)
        segments: list[Segment] = []
        for i, (start, end) in enumerate(bounds):
            chunk = audio[start:end]
            if chunk.size and float(np.sqrt(np.mean(chunk**2))) >= SILENCE_RMS:
                offset = start / SAMPLE_RATE
                segments += [
                    Segment(s.start + offset, s.end + offset, s.text)
                    for s in self.engine.transcribe(chunk, self.prompt())
                ]
            if on_progress:
                on_progress((i + 1) / len(bounds))
        return clean_segments(segments)
