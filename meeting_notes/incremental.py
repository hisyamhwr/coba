"""Transkripsi di latar belakang selama rapat berjalan.

Aplikasi Mac menjalankan `python -m meeting_notes ikuti <folder rekaman>` saat mulai merekam. Proses ini membaca
`sistem.wav` dan `mic.wav` yang terus bertambah, lalu mentranskripsi setiap potongan +-2 menit yang sudah
lengkap. Hasilnya disimpan ke `transkrip_parsial.json` setelah setiap potongan, sehingga saat rapat selesai
`proses` hanya perlu mentranskripsi sisa beberapa menit terakhir, berapa pun panjang rapatnya.

Proses ini boleh dihentikan kapan saja (aplikasi menghentikannya saat rapat selesai): potongan yang belum
selesai akan dikerjakan ulang oleh `proses`.
"""

import json
import os
import struct
import time
from collections.abc import Callable
from pathlib import Path

import numpy as np

from .transcriber import FAST_MODEL, SAMPLE_RATE, Segment, Transcriber, chunk_bounds

STATE_FILE = "transkrip_parsial.json"
TRACKS = {"sistem": "sistem.wav", "mic": "mic.wav"}
LIVE_CHUNK_SECONDS = 120
# Bila transkripsi butuh lebih dari 60% durasi audio (dua jalur bergantian), Mac tidak akan mengejar rapat:
# turun ke model turbo yang +-3x lebih cepat.
MAX_REALTIME_FACTOR = 0.6


class GrowingWav:
    """Membaca WAV PCM 16 kHz mono yang masih ditulis (ukuran di header belum diperbarui)."""

    def __init__(self, path: Path):
        self.path = path
        self.data_offset: int | None = None
        self.sample_width = 2

    def _find_data(self) -> bool:
        if not self.path.exists():
            return False
        with self.path.open("rb") as f:
            header = f.read(65536)
        if header[:4] != b"RIFF" or header[8:12] != b"WAVE":
            return False
        pos = 12
        while pos + 8 <= len(header):
            chunk_id = header[pos:pos + 4]
            size = struct.unpack("<I", header[pos + 4:pos + 8])[0]
            if chunk_id == b"fmt ":
                bits = struct.unpack("<H", header[pos + 22:pos + 24])[0]
                self.sample_width = bits // 8
            elif chunk_id == b"data":
                self.data_offset = pos + 8
                return True
            pos += 8 + size + (size & 1)
        return False

    def samples(self) -> int:
        if self.data_offset is None and not self._find_data():
            return 0
        return max(0, (self.path.stat().st_size - self.data_offset) // self.sample_width)

    def read(self, start: int, end: int) -> np.ndarray:
        with self.path.open("rb") as f:
            f.seek(self.data_offset + start * self.sample_width)
            raw = f.read((end - start) * self.sample_width)
        if self.sample_width == 4:
            return np.frombuffer(raw[: len(raw) // 4 * 4], dtype="<f4").astype(np.float32)
        return np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768


def load_state(folder: Path) -> dict:
    """{"sistem": {"until": detik, "segments": [[mulai, selesai, teks], ...]}, "mic": {...}}"""
    try:
        state = json.loads((folder / STATE_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def save_state(folder: Path, state: dict) -> None:
    # Tulis ke file sementara lalu ganti, agar file tidak pernah setengah jadi bila proses dihentikan.
    tmp = folder / (STATE_FILE + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, folder / STATE_FILE)


def track_segments(state: dict, name: str) -> tuple[float, list[Segment]]:
    track = state.get(name) or {}
    segments = [Segment(float(a), float(b), str(t)) for a, b, t in track.get("segments", [])]
    return float(track.get("until", 0.0)), segments


def advance(folder: Path, state: dict, transcriber: Transcriber, name: str, reader: GrowingWav) -> float:
    """Transkripsi potongan lengkap yang belum dikerjakan. Mengembalikan detik audio yang ditranskripsi."""
    until, segments = track_segments(state, name)
    start = int(until * SAMPLE_RATE)
    available = reader.samples()
    if available - start < (LIVE_CHUNK_SECONDS + 20) * SAMPLE_RATE:
        return 0.0
    audio = reader.read(start, available)
    # Potongan terakhir belum lengkap (rapat masih berjalan): dikerjakan pada putaran berikutnya.
    bounds = chunk_bounds(audio, chunk_seconds=LIVE_CHUNK_SECONDS)[:-1]
    done = 0.0
    for a, b in bounds:
        segments += transcriber.transcribe_chunk(audio[a:b], (start + a) / SAMPLE_RATE)
        until = (start + b) / SAMPLE_RATE
        done += (b - a) / SAMPLE_RATE
        state[name] = {"until": until, "segments": [[s.start, s.end, s.text] for s in segments]}
        state["model"] = transcriber.model_size
        save_state(folder, state)
    return done


def follow(folder: Path, transcriber: Transcriber, log: Callable[[str], None] = print,
           poll_seconds: float = 5.0, should_stop: Callable[[], bool] = lambda: False) -> None:
    """Ikuti rekaman sampai dihentikan, atau sampai aplikasi Mac yang menjalankannya tertutup."""
    parent = os.getppid()
    readers = {name: GrowingWav(folder / file) for name, file in TRACKS.items()}
    state = load_state(folder)
    log(f"Mengikuti rekaman dengan model {transcriber.model_size}")
    # Potongan pertama setelah model dimuat ikut menanggung waktu memuat model, jadi tidak dipakai mengukur.
    measured = False
    while not should_stop() and os.getppid() == parent:
        for name, reader in readers.items():
            began = time.monotonic()
            seconds = advance(folder, state, transcriber, name, reader)
            if not seconds:
                continue
            factor = (time.monotonic() - began) / seconds
            log(f"{name}: {seconds:.0f} detik audio ditranskripsi dalam {factor:.2f}x durasinya")
            too_slow = factor > MAX_REALTIME_FACTOR / len(readers)
            if measured and too_slow and transcriber.model_size != FAST_MODEL:
                log(f"Terlalu lambat untuk mengejar rapat; beralih ke {FAST_MODEL}")
                transcriber.use_model(FAST_MODEL)
                measured = False
            else:
                measured = True
        time.sleep(poll_seconds)
