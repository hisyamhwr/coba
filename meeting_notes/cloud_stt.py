"""Mesin transkripsi cloud untuk campuran Indonesia-Inggris.

Audio dikirim ke penyedia (ElevenLabs, AssemblyAI, atau Deepgram) dan hasilnya dikembalikan sebagai Segment.
Kamus otomatis dikirim sebagai "keyterms" agar istilah kantor dikenali.
"""

import os
import time
from dataclasses import dataclass
from pathlib import Path

import requests

from .transcriber import Segment

TIMEOUT = 600


@dataclass
class Provider:
    name: str
    env_key: str
    # Perkiraan harga transkripsi batch per jam audio (USD); cek halaman harga penyedia untuk angka terbaru.
    usd_per_hour: float

    @property
    def api_key(self) -> str | None:
        return os.getenv(self.env_key) or None

    def transcribe(self, audio_path: Path, keyterms: list[str]) -> list[Segment]:
        raise NotImplementedError


def _mime(path: Path) -> str:
    return {".wav": "audio/wav", ".flac": "audio/flac", ".mp3": "audio/mpeg", ".m4a": "audio/mp4"}.get(
        path.suffix.lower(), "application/octet-stream")


def _clean_keyterms(terms: list[str], limit: int) -> list[str]:
    return [t for t in terms if 0 < len(t) <= 50 and len(t.split()) <= 5][:limit]


def _words_to_segments(words: list[tuple[float, float, str, str | None]], max_gap: float = 1.0) -> list[Segment]:
    """Gabungkan kata menjadi segmen; segmen baru saat pembicara berganti atau ada jeda."""
    segments: list[Segment] = []
    for start, end, text, speaker in words:
        last = segments[-1] if segments else None
        if last and last.speaker == speaker and start - last.end <= max_gap and len(last.text) < 400:
            segments[-1] = Segment(last.start, end, f"{last.text} {text}".strip(), speaker)
        else:
            segments.append(Segment(start, end, text.strip(), speaker))
    return [s for s in segments if s.text]


class ElevenLabs(Provider):
    def __init__(self):
        super().__init__("ElevenLabs Scribe v2", "ELEVENLABS_API_KEY", 0.22)

    def transcribe(self, audio_path: Path, keyterms: list[str]) -> list[Segment]:
        data = [("model_id", "scribe_v2"), ("diarize", "true"), ("tag_audio_events", "false")]
        data += [("keyterms", t) for t in _clean_keyterms(keyterms, 100)]
        with audio_path.open("rb") as f:
            resp = requests.post(
                "https://api.elevenlabs.io/v1/speech-to-text",
                headers={"xi-api-key": self.api_key},
                data=data, files={"file": (audio_path.name, f, _mime(audio_path))}, timeout=TIMEOUT,
            )
        resp.raise_for_status()
        words = [
            (w["start"], w["end"], w["text"], w.get("speaker_id"))
            for w in resp.json().get("words", [])
            if w.get("type") == "word"
        ]
        return _words_to_segments(words)


class AssemblyAI(Provider):
    BASE = "https://api.assemblyai.com/v2"

    def __init__(self):
        super().__init__("AssemblyAI Universal-3.5 Pro", "ASSEMBLYAI_API_KEY", 0.21)

    def transcribe(self, audio_path: Path, keyterms: list[str]) -> list[Segment]:
        headers = {"authorization": self.api_key}
        with audio_path.open("rb") as f:
            upload = requests.post(f"{self.BASE}/upload", headers=headers, data=f, timeout=TIMEOUT)
        upload.raise_for_status()
        body = {
            "audio_url": upload.json()["upload_url"],
            # Model pertama dipakai bila mendukung bahasanya; jika tidak, otomatis jatuh ke model berikutnya.
            "speech_models": ["universal-3-5-pro", "universal-2"],
            "language_detection": True,
            "language_detection_options": {"expected_languages": ["id", "en"], "code_switching": True},
            "speaker_labels": True,
        }
        if terms := _clean_keyterms(keyterms, 1000):
            body["keyterms_prompt"] = terms
        job = requests.post(f"{self.BASE}/transcript", headers=headers, json=body, timeout=60)
        job.raise_for_status()
        url = f"{self.BASE}/transcript/{job.json()['id']}"
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            result = requests.get(url, headers=headers, timeout=60).json()
            if result["status"] == "completed":
                return [
                    Segment(u["start"] / 1000, u["end"] / 1000, u["text"], f"speaker_{u['speaker']}")
                    for u in result.get("utterances") or []
                ] or [Segment(0, 0, result.get("text") or "")]
            if result["status"] == "error":
                raise RuntimeError(result.get("error", "AssemblyAI gagal"))
            time.sleep(3)
        raise TimeoutError("AssemblyAI terlalu lama")


class Deepgram(Provider):
    def __init__(self):
        super().__init__("Deepgram Nova-3", "DEEPGRAM_API_KEY", 0.26)

    def transcribe(self, audio_path: Path, keyterms: list[str]) -> list[Segment]:
        params = [("model", "nova-3"), ("language", "id"), ("smart_format", "true"),
                  ("diarize", "true"), ("utterances", "true")]
        params += [("keyterm", t) for t in _clean_keyterms(keyterms, 50)]
        with audio_path.open("rb") as f:
            resp = requests.post(
                "https://api.deepgram.com/v1/listen", params=params, data=f, timeout=TIMEOUT,
                headers={"Authorization": f"Token {self.api_key}", "Content-Type": _mime(audio_path)},
            )
        resp.raise_for_status()
        return [
            Segment(u["start"], u["end"], u["transcript"], f"speaker_{u.get('speaker', 0)}")
            for u in resp.json()["results"].get("utterances", [])
        ]


PROVIDERS: dict[str, type[Provider]] = {
    "elevenlabs": ElevenLabs,
    "assemblyai": AssemblyAI,
    "deepgram": Deepgram,
}


def transcribe_with_fallback(provider: Provider, audio_path: Path, keyterms: list[str]) -> list[Segment]:
    """Jika penyedia menolak keyterms (HTTP 400), ulangi tanpa keyterms."""
    try:
        return provider.transcribe(audio_path, keyterms)
    except requests.HTTPError as exc:
        if keyterms and exc.response is not None and exc.response.status_code == 400:
            return provider.transcribe(audio_path, [])
        raise
