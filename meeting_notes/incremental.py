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
import time
from collections.abc import Callable
from pathlib import Path

from .transcriber import FAST_MODEL, SAMPLE_RATE, Segment, Transcriber, iter_chunks
from .wavio import GrowingWav

STATE_FILE = "transkrip_parsial.json"
TRACKS = {"sistem": "sistem.wav", "mic": "mic.wav"}
LIVE_CHUNK_SECONDS = 120
# Bila transkripsi butuh lebih dari 40% durasi audio (dua jalur bergantian), Mac terlalu sibuk selama rapat
# (Zoom/Teams bisa tersendat) dan berisiko tidak mengejar: turun ke model turbo yang +-3x lebih cepat.
MAX_REALTIME_FACTOR = 0.4
# Jeda setelah error (mis. model gagal diunduh) sebelum mencoba lagi; proses akhir tetap mengerjakan sisanya.
ERROR_BACKOFF_SECONDS = 30


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
    if reader.samples() - start < (LIVE_CHUNK_SECONDS + 20) * SAMPLE_RATE:
        return 0.0
    done = 0.0
    # Potongan terakhir belum lengkap (rapat masih berjalan): dikerjakan pada putaran berikutnya.
    for pos, chunk in iter_chunks(reader, start, LIVE_CHUNK_SECONDS, include_last=False):
        segments += transcriber.transcribe_chunk(chunk, pos / SAMPLE_RATE)
        until = (pos + len(chunk)) / SAMPLE_RATE
        done += len(chunk) / SAMPLE_RATE
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
            try:
                seconds = advance(folder, state, transcriber, name, reader)
            except Exception as exc:  # noqa: BLE001 - jangan berhenti; proses akhir mengerjakan sisanya
                log(f"{name}: gagal mentranskripsi ({type(exc).__name__}: {exc}); dicoba lagi nanti")
                time.sleep(ERROR_BACKOFF_SECONDS)
                continue
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
