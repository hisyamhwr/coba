"""Simulasi rapat untuk mengukur jeda koreksi live: detik dari akhir ucapan sampai teks Whisper tampil.

Dua jalur sintetis (peserta online + mic dengan derau ruangan dan gema speaker), ucapan 1-7 detik dengan jeda
alami, biaya transkripsi seperti large-v3-turbo di M1 (COST=3 untuk Mac yang lebih lambat), audio bertambah
seperti rapat sungguhan. Dipakai tes regresi (tests/test_meeting_notes.py) dan untuk membandingkan versi:

    python tools/simulasi_live.py [incremental_versi_lama.py]       # MINUTES=70 COST=3 opsional
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from meeting_notes.transcriber import SAMPLE_RATE as SR, Segment  # noqa: E402

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

import os
COST = float(os.environ.get('COST', '1'))
rng = np.random.default_rng(7)

def make_tracks(minutes=20):
    n = int(minutes * 60 * SR)
    system = (rng.standard_normal(n) * 0.0004).astype(np.float32)  # audio digital: nyaris hening
    mic = (rng.standard_normal(n) * 0.004).astype(np.float32)      # derau ruangan + kipas laptop
    utterances = []  # (track, start, end)
    t = 2.0
    while t < minutes * 60 - 15:
        track = "mic" if rng.random() < 0.25 else "sistem"
        dur = float(rng.uniform(1.0, 7.0))
        a, b = int(t * SR), int((t + dur) * SR)
        tt = np.arange(b - a) / SR
        # "ucapan": nada dengan selubung suku kata (4 Hz) agar ada jeda mikro seperti bicara sungguhan
        env = 0.5 + 0.5 * np.abs(np.sin(2 * np.pi * 2.0 * tt))
        level = 0.08 if track == "sistem" else 0.05
        sig = (level * env * np.sin(2 * np.pi * 220 * tt)).astype(np.float32)
        (system if track == "sistem" else mic)[a:b] += sig
        if track == "sistem":  # gema dari speaker ikut masuk mic, lebih pelan
            mic[a:b] += sig * 0.15
        utterances.append((track, t, t + dur))
        t += dur + float(rng.choice([0.3, 0.6, 0.9, 1.5, 3.0]))
    return {"sistem": system, "mic": mic}, utterances

class GrowingArray:
    def __init__(self, data):
        self.data, self.now = data, 0.0
    def samples(self):
        return min(len(self.data), int(self.now * SR))
    def read(self, start=0, end=None):
        end = self.samples() if end is None else min(end, self.samples())
        return self.data[start:end]

class FakeWhisper:
    """Biaya seperti large-v3-turbo di M1: 0,45 s overhead per panggilan + 0,05x durasi audio."""
    model_size = "large-v3-turbo"
    def __init__(self, utterances):
        self.utterances, self.last_context, self.cost, self.calls = utterances, "", 0.0, 0
    def transcribe_chunk(self, chunk, offset=0.0, context=""):
        from meeting_notes.transcriber import Condensed
        end = offset + len(chunk) / SR
        condensed = Condensed(chunk)
        if condensed.seconds < 0.5:
            self.cost = 0.02
            return []
        self.calls += 1
        self.cost = COST * (0.45 + 0.05 * condensed.seconds)
        segs = []
        for i, a, b in self.utterances:
            if offset <= (a + b) / 2 < end:
                # Whisper hanya melihat potongan ini: waktu segmen tidak bisa sebelum awal potongan.
                segs.append(Segment(max(a, offset), min(b, end), f"u{i}"))
        return segs

def run(mod, tracks, utterances, minutes):
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        mod.save_state = lambda folder, state: None  # tulis file tidak diukur
        readers = {name: GrowingArray(data) for name, data in tracks.items()}
        whisper = {name: FakeWhisper([(i, a, b) for i, (t, a, b) in enumerate(utterances) if t == name])
                   for name in tracks}
        state, emitted, clock = {}, 0.0, 0.0
        shown = {}
        while clock < minutes * 60:
            worked = False
            for name, reader in readers.items():
                for r in readers.values():
                    r.now = clock
                w = whisper[name]
                w.cost = 0.0
                kwargs = {"max_chunks": 1}
                seconds = mod.advance(folder, state, w, name, reader, **kwargs)
                if seconds:
                    worked = True
                    clock += w.cost
            emitted, segments = mod.live_update(state, emitted)
            for s in segments:
                shown.setdefault(s.text, clock)
            if not worked:
                clock += getattr(mod, "POLL_SECONDS", 1.0)
        lat = []
        for i, (track, a, b) in enumerate(utterances):
            if f"u{i}" in shown:
                lat.append(shown[f"u{i}"] - b)
        calls = sum(w.calls for w in whisper.values())
        left = max(len(tracks[n]) / SR - float(state.get(n, {}).get('until', 0)) for n in tracks)
        return np.array(lat), len(utterances), calls, left

if __name__ == "__main__":
    minutes = int(os.environ.get('MINUTES', '20'))
    tracks, utterances = make_tracks(minutes)
    current = Path(__file__).resolve().parents[1] / "meeting_notes" / "incremental.py"
    versions = [("pembanding", sys.argv[1])] if len(sys.argv) > 1 else []
    for label, path in versions + [("sekarang", str(current))]:
        mod = load(path, "meeting_notes._sim_" + label.split()[0])
        lat, total, calls, left = run(mod, tracks, utterances, minutes)
        print(f"{label:14s} tampil {len(lat)}/{total} ucapan | jeda median {np.median(lat):.1f} s, "
              f"p90 {np.percentile(lat, 90):.1f} s, maks {lat.max():.1f} s | Whisper {calls}x | sisa saat rapat selesai {left:.0f} s")
