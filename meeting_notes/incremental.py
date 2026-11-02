"""Transkripsi di latar belakang selama rapat berjalan, sekaligus koreksi transkrip live.

Aplikasi Mac menjalankan `python -m meeting_notes ikuti <folder rekaman>` saat mulai merekam. Proses ini membaca
`sistem.wav` dan `mic.wav` yang terus bertambah dan mentranskripsi potongan pendek (+-6-12 detik, dipotong di
jeda bicara) bergantian per jalur. Setiap potongan:
- disimpan ke `transkrip_parsial.json`, sehingga saat rapat selesai `proses` hanya perlu mentranskripsi
  beberapa detik terakhir, berapa pun panjang rapatnya;
- dikirim ke aplikasi sebagai baris `LIVE` (lihat `follow`), yang mengganti kata-kata kasar dari pengenal
  suara Apple dengan hasil Whisper (lebih akurat, memakai kamus istilah) beberapa detik setelah diucapkan.

Proses ini boleh dihentikan kapan saja (aplikasi menghentikannya saat rapat selesai): potongan yang belum
selesai akan dikerjakan ulang oleh `proses`.
"""

import json
import os
import time
from collections.abc import Callable
from pathlib import Path

from .transcriber import (
    FAST_MODEL,
    SAMPLE_RATE,
    Segment,
    Transcriber,
    iter_chunks,
    merge_tracks,
)
from .wavio import GrowingWav

STATE_FILE = "transkrip_parsial.json"
TRACKS = {"sistem": "sistem.wav", "mic": "mic.wav"}
# Potongan pendek agar koreksi live muncul beberapa detik setelah diucapkan: dipotong di titik paling sunyi
# antara detik ke-6 dan ke-12. Setiap potongan diberi akhir kalimat potongan sebelumnya sebagai konteks.
LIVE_CHUNK_SECONDS = 12
LIVE_CUT_SEARCH_SECONDS = 6
# Bila transkripsi butuh lebih dari 40% durasi audio (dua jalur bergantian), Mac terlalu sibuk selama rapat
# (Zoom/Teams bisa tersendat) dan berisiko tidak mengejar: turun ke model turbo yang +-3x lebih cepat.
MAX_REALTIME_FACTOR = 0.4
# Jeda setelah error (mis. model gagal diunduh) sebelum mencoba lagi; proses akhir tetap mengerjakan sisanya.
ERROR_BACKOFF_SECONDS = 30
POLL_SECONDS = 1.0


def load_state(folder: Path) -> dict:
    """{"sistem": {"until": detik, "segments": [[mulai, selesai, teks], ...], "context": teks}, "mic": {...}}"""
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


def advance(folder: Path, state: dict, transcriber: Transcriber, name: str, reader: GrowingWav,
            max_chunks: int | None = None) -> float:
    """Transkripsi potongan lengkap yang belum dikerjakan (paling banyak max_chunks).

    Mengembalikan detik audio yang ditranskripsi.
    """
    until, segments = track_segments(state, name)
    context = str((state.get(name) or {}).get("context", ""))
    start = int(until * SAMPLE_RATE)
    if reader.samples() - start < (LIVE_CHUNK_SECONDS + 1) * SAMPLE_RATE:
        return 0.0
    done = 0.0
    # Potongan terakhir belum lengkap (rapat masih berjalan): dikerjakan pada putaran berikutnya.
    chunks = iter_chunks(reader, start, LIVE_CHUNK_SECONDS, include_last=False, search_seconds=LIVE_CUT_SEARCH_SECONDS)
    for count, (pos, chunk) in enumerate(chunks, start=1):
        segments += transcriber.transcribe_chunk(chunk, pos / SAMPLE_RATE, context=context)
        context = getattr(transcriber, "last_context", "")
        until = (pos + len(chunk)) / SAMPLE_RATE
        done += len(chunk) / SAMPLE_RATE
        state[name] = {"until": until, "segments": [[s.start, s.end, s.text] for s in segments], "context": context}
        state["model"] = transcriber.model_size
        save_state(folder, state)
        if max_chunks is not None and count >= max_chunks:
            break
    return done


def live_update(state: dict, emitted_until: float) -> tuple[float, list[Segment]]:
    """Segmen baru yang siap ditampilkan: sampai titik yang sudah ditranskripsi di KEDUA jalur.

    Gema suara peserta yang ikut tertangkap mic (saat memakai speaker) dibuang lewat merge_tracks, jadi kalimat
    tidak tampil dua kali. Mengembalikan (batas waktu baru, segmen urut waktu).
    """
    tracks = {name: track_segments(state, name) for name in TRACKS}
    until = min(progress for progress, _ in tracks.values())
    if until <= emitted_until:
        return emitted_until, []

    def fresh(name: str) -> list[Segment]:
        return [s for s in tracks[name][1] if emitted_until <= s.start < until]

    return until, merge_tracks(fresh("sistem"), fresh("mic"))


def follow(folder: Path, transcriber: Transcriber, log: Callable[[str], None] = print,
           poll_seconds: float = POLL_SECONDS, should_stop: Callable[[], bool] = lambda: False,
           on_live: Callable[[float, list[Segment]], None] = lambda until, segments: None) -> None:
    """Ikuti rekaman sampai dihentikan, atau sampai aplikasi Mac yang menjalankannya tertutup.

    Jalur diproses bergantian satu potongan per giliran agar keduanya maju bersama; on_live dipanggil setiap ada
    segmen baru yang sudah ditranskripsi di kedua jalur.
    """
    parent = os.getppid()
    readers = {name: GrowingWav(folder / file) for name, file in TRACKS.items()}
    state = load_state(folder)
    emitted, _ = live_update(state, 0.0)
    log(f"Mengikuti rekaman dengan model {transcriber.model_size}")
    # Potongan pertama setelah model dimuat ikut menanggung waktu memuat model, jadi tidak dipakai mengukur.
    measured = False
    # Waktu kerja dan durasi audio sejak pengukuran terakhir: potongan pendek diukur bersama agar adil.
    busy, audio = 0.0, 0.0
    while not should_stop() and os.getppid() == parent:
        worked = False
        for name, reader in readers.items():
            began = time.monotonic()
            try:
                seconds = advance(folder, state, transcriber, name, reader, max_chunks=1)
            except Exception as exc:  # noqa: BLE001 - jangan berhenti; proses akhir mengerjakan sisanya
                log(f"{name}: gagal mentranskripsi ({type(exc).__name__}: {exc}); dicoba lagi nanti")
                time.sleep(ERROR_BACKOFF_SECONDS)
                continue
            if not seconds:
                continue
            worked = True
            busy += time.monotonic() - began
            audio += seconds
        emitted, segments = live_update(state, emitted)
        if segments:
            on_live(emitted, segments)
        if audio >= 60:
            factor = busy / audio
            log(f"{audio:.0f} detik audio ditranskripsi dalam {factor:.2f}x durasinya")
            too_slow = factor > MAX_REALTIME_FACTOR
            if measured and too_slow and transcriber.model_size != FAST_MODEL:
                log(f"Terlalu lambat untuk mengejar rapat; beralih ke {FAST_MODEL}")
                transcriber.use_model(FAST_MODEL)
                measured = False
            else:
                measured = True
            busy, audio = 0.0, 0.0
        if not worked:
            time.sleep(poll_seconds)
