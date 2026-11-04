"""Transkripsi di latar belakang selama rapat berjalan, sekaligus koreksi transkrip live.

Aplikasi Mac menjalankan `python -m meeting_notes ikuti <folder rekaman>` saat mulai merekam. Proses ini membaca
`sistem.wav` dan `mic.wav` yang terus bertambah dan mentranskripsi per ucapan: begitu ada jeda bicara +-0,4 detik
(atau paling lama 10 detik bicara tanpa jeda), potongan itu langsung ditranskripsi, bergantian per jalur. Bagian
yang hanya berisi derau (mis. mic saat kamu mendengarkan) dilewati tanpa memanggil Whisper. Setiap potongan:
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

import numpy as np

from .transcriber import (
    FAST_MODEL,
    SAMPLE_RATE,
    Segment,
    Transcriber,
    merge_tracks,
)
from .wavio import GrowingWav

STATE_FILE = "transkrip_parsial.json"
TRACKS = {"sistem": "sistem.wav", "mic": "mic.wav"}
# Potongan per ucapan agar koreksi live muncul 1-3 detik setelah kalimat selesai. Setiap potongan diberi akhir
# kalimat potongan sebelumnya sebagai konteks.
LIVE_MIN_SECONDS = 1.5      # potongan terpendek (ucapan sangat pendek digabung dengan jeda sesudahnya)
LIVE_MAX_SECONDS = 10.0     # bicara tanpa jeda dipotong di titik paling sunyi paling lambat di sini
LIVE_PAUSE_SECONDS = 0.4    # jeda yang menandai akhir ucapan
LIVE_FRAME = SAMPLE_RATE // 20   # 50 ms
# Di atas derau ruangan x NOISE_MARGIN dianggap suara. Batas bawah sama dengan ambang minimum speech_spans,
# jadi bagian yang dilewati di sini juga tidak akan dianggap suara oleh transkripsi akhir.
NOISE_MARGIN = 2.5
SILENCE_LEVEL = 1.5e-3
# Pengaman: level di atas ini (-40 dBFS) selalu dianggap suara, walau perkiraan derau keliru tinggi (mis. rekaman
# dimulai saat orang sedang bicara tanpa jeda). Ucapan tidak pernah dilewati sebagai derau.
SPEECH_ALWAYS = 0.01
# Bila transkripsi butuh lebih dari 40% durasi audio (dua jalur bergantian), Mac terlalu sibuk selama rapat
# (Zoom/Teams bisa tersendat) dan berisiko tidak mengejar: turun ke model turbo yang +-3x lebih cepat.
MAX_REALTIME_FACTOR = 0.4
# Jeda setelah error (mis. model gagal diunduh) sebelum mencoba lagi; proses akhir tetap mengerjakan sisanya.
ERROR_BACKOFF_SECONDS = 30
POLL_SECONDS = 0.5


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


def frame_levels(audio: np.ndarray, frame: int = LIVE_FRAME) -> np.ndarray:
    n = len(audio) // frame
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    return np.sqrt((audio[: n * frame].reshape(-1, frame) ** 2).mean(axis=1))


def update_floor(floor: float, levels: np.ndarray) -> float:
    """Perkiraan derau ruangan jalur ini (persentil 10 level per 50 ms, dirata-rata antar-jendela).

    Bila jendela penuh bicara (persentil 10 jauh di atas derau), perkiraan hanya naik sangat pelan.
    """
    if levels.size == 0:
        return floor
    low = float(np.percentile(levels, 10))
    if floor <= 0:
        return low
    weight = 0.2 if low < floor * 4 else 0.02
    return (1 - weight) * floor + weight * low


def plan_cut(window: np.ndarray, floor: float, complete: bool) -> tuple[int, bool] | None:
    """Potongan live berikutnya dari awal `window`: (panjang dalam sampel, berisi suara?), atau None (tunggu).

    - Ada jeda >= LIVE_PAUSE_SECONDS setelah suara: dipotong di tengah jeda (ucapan selesai).
    - Tidak ada suara: dilewati tanpa transkripsi, sisakan ekor pendek bila suara baru akan mulai.
    - Hening panjang di depan lalu suara: heningnya dilewati dulu.
    - Bicara terus tanpa jeda: tunggu, sampai `complete` (jendela sudah selebar maksimum) lalu dipotong di
      titik paling sunyi.
    """
    levels = frame_levels(window)
    n = levels.size
    per_second = SAMPLE_RATE // LIVE_FRAME
    min_frames = int(LIVE_MIN_SECONDS * per_second)
    pause = int(LIVE_PAUSE_SECONDS * per_second)
    if n < min_frames:
        return None
    loud = levels >= max(SILENCE_LEVEL, min(floor * NOISE_MARGIN, SPEECH_ALWAYS))
    if not loud.any():
        return ((n - pause) * LIVE_FRAME, False) if n - pause >= min_frames else None
    first = int(np.argmax(loud))
    if first >= min_frames:
        return ((first - pause // 2) * LIVE_FRAME, False)
    run_start = -1
    for i in range(first, n):
        if loud[i]:
            run_start = -1
            continue
        if run_start < 0:
            run_start = i
        if i - run_start + 1 >= pause and i >= min_frames:
            return (max(run_start + pause // 2, min_frames) * LIVE_FRAME, True)
    if not complete:
        return None
    max_frames = min(n, int(LIVE_MAX_SECONDS * per_second))
    quietest = min_frames + int(np.argmin(levels[min_frames:max_frames]))
    return (quietest * LIVE_FRAME, True)


def advance(folder: Path, state: dict, transcriber: Transcriber, name: str, reader: GrowingWav,
            max_chunks: int | None = None) -> float:
    """Kerjakan audio baru jalur ini per ucapan (paling banyak max_chunks potongan bersuara).

    Mengembalikan detik audio yang maju (ditranskripsi atau dilewati karena hanya derau).
    """
    until, segments = track_segments(state, name)
    track = state.get(name) or {}
    context = str(track.get("context", ""))
    floor = float(track.get("floor", 0.0))
    done, spoken = 0.0, 0
    window_samples = int((LIVE_MAX_SECONDS + LIVE_PAUSE_SECONDS) * SAMPLE_RATE)
    while max_chunks is None or spoken < max_chunks:
        start = round(until * SAMPLE_RATE)
        end = min(reader.samples(), start + window_samples)
        if end - start < int(LIVE_MIN_SECONDS * SAMPLE_RATE):
            break
        window = reader.read(start, end)
        floor = update_floor(floor, frame_levels(window))
        plan = plan_cut(window, floor, complete=len(window) >= window_samples)
        if plan is None:
            break
        cut, has_speech = plan
        if has_speech:
            segments += transcriber.transcribe_chunk(window[:cut], start / SAMPLE_RATE, context=context)
            context = getattr(transcriber, "last_context", "")
            spoken += 1
        until = (start + cut) / SAMPLE_RATE
        done += cut / SAMPLE_RATE
        state[name] = {"until": until, "segments": [[s.start, s.end, s.text] for s in segments],
                       "context": context, "floor": floor}
        state["model"] = transcriber.model_size
        save_state(folder, state)
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
