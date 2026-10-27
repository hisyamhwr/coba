"""Merekam mikrofon (dan opsional audio sistem) ke file WAV di perangkat lokal."""

import sys
import threading
from pathlib import Path

import numpy as np
import soundfile as sf

BLOCK_SECONDS = 0.1


class _Track(threading.Thread):
    """Satu sumber audio yang direkam ke file WAV-nya sendiri."""

    def __init__(self, source, path: Path, sample_rate: int, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.source = source
        self.path = path
        self.sample_rate = sample_rate
        self.stop_event = stop_event
        self.level = 0.0
        self.error: Exception | None = None

    def run(self) -> None:
        frames = int(self.sample_rate * BLOCK_SECONDS)
        if sys.platform == "win32":
            # Driver audio Windows (WASAPI) butuh COM diinisialisasi di setiap thread.
            import ctypes

            ctypes.windll.ole32.CoInitializeEx(None, 0)
        try:
            with sf.SoundFile(self.path, "w", self.sample_rate, 1, "PCM_16") as out, \
                    self.source.recorder(samplerate=self.sample_rate, channels=1) as rec:
                while not self.stop_event.is_set():
                    block = rec.record(numframes=frames)
                    mono = block.mean(axis=1) if block.ndim > 1 else block
                    out.write(mono)
                    self.level = float(np.sqrt(np.mean(mono**2))) if mono.size else 0.0
        except Exception as exc:  # noqa: BLE001 - dilaporkan ke UI lewat Recorder.errors
            self.error = exc


class Recorder:
    def __init__(self, workdir: Path, sample_rate: int = 16000, capture_system_audio: bool = True):
        self.workdir = workdir
        self.sample_rate = sample_rate
        self.capture_system_audio = capture_system_audio
        self._stop = threading.Event()
        self._tracks: list[_Track] = []
        self.mic_name = ""

    def start(self) -> list[str]:
        """Mulai merekam. Mengembalikan peringatan (mis. audio sistem tidak tersedia)."""
        import soundcard as sc  # diimpor di sini karena butuh driver audio saat import

        self.workdir.mkdir(parents=True, exist_ok=True)
        self._stop.clear()
        warnings: list[str] = []

        mic = sc.default_microphone()
        self.mic_name = mic.name
        sources = [("mic", mic)]
        if self.capture_system_audio:
            try:
                speaker = sc.default_speaker()
                sources.append(("system", sc.get_microphone(id=str(speaker.name), include_loopback=True)))
            except Exception as exc:  # noqa: BLE001
                warnings.append(f"Audio sistem tidak bisa direkam ({exc}); hanya mikrofon.")

        self._tracks = [
            _Track(src, self.workdir / f"{name}.wav", self.sample_rate, self._stop) for name, src in sources
        ]
        for track in self._tracks:
            track.start()
        return warnings

    @property
    def level(self) -> float:
        return max((t.level for t in self._tracks), default=0.0)

    @property
    def errors(self) -> list[Exception]:
        return [t.error for t in self._tracks if t.error]

    def stop(self) -> Path:
        """Hentikan rekaman dan gabungkan semua sumber menjadi satu file WAV."""
        self._stop.set()
        for track in self._tracks:
            track.join()
        paths = [t.path for t in self._tracks if t.path.exists() and t.error is None]
        if not paths:
            raise RuntimeError(f"Rekaman gagal: {self.errors}")
        return mix_tracks(paths, self.workdir / "meeting.wav", self.sample_rate)


def mix_tracks(paths: list[Path], out_path: Path, sample_rate: int, blocksize: int = 160_000) -> Path:
    """Gabungkan beberapa WAV mono menjadi satu, blok demi blok agar hemat memori."""
    readers = [sf.SoundFile(p) for p in paths]
    try:
        with sf.SoundFile(out_path, "w", sample_rate, 1, "PCM_16") as out:
            while True:
                blocks = [r.read(blocksize, dtype="float32") for r in readers]
                length = max(len(b) for b in blocks)
                if length == 0:
                    break
                mixed = np.zeros(length, dtype="float32")
                for b in blocks:
                    mixed[: len(b)] += b
                out.write(np.clip(mixed, -1.0, 1.0))
    finally:
        for r in readers:
            r.close()
    return out_path
