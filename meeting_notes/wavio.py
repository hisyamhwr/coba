"""Membaca WAV PCM rekaman aplikasi Mac secara tangguh.

Rekaman yang masih berjalan, atau yang tidak sempat ditutup rapi (aplikasi tertutup paksa, Mac mati), punya
header WAV dengan ukuran data 0 atau salah. Pembaca audio biasa menganggapnya kosong. Modul ini mencari blok
`data` lalu memakai ukuran file sebenarnya, sehingga rekaman seperti itu tetap bisa diproses.
"""

import struct
from pathlib import Path

import numpy as np


class GrowingWav:
    """Membaca WAV PCM (16-bit atau float 32-bit) mono yang mungkin masih ditulis atau headernya rusak."""

    def __init__(self, path: Path):
        self.path = path
        self.data_offset: int | None = None
        self.data_size = 0
        self.sample_width = 2
        self.channels = 0
        self.sample_rate = 0

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
                self.channels, self.sample_rate = struct.unpack("<HI", header[pos + 10:pos + 16])
                bits = struct.unpack("<H", header[pos + 22:pos + 24])[0]
                self.sample_width = max(1, bits // 8)
            elif chunk_id == b"data":
                self.data_offset = pos + 8
                self.data_size = size
                return True
            pos += 8 + size + (size & 1)
        return False

    def samples(self) -> int:
        if self.data_offset is None and not self._find_data():
            return 0
        available = max(0, self.path.stat().st_size - self.data_offset)
        # Ukuran di header dipakai hanya bila masuk akal (file sudah ditutup rapi dan mungkin ada blok lain
        # sesudah data); saat masih ditulis atau rusak, ukurannya 0 atau melebihi isi file.
        if 0 < self.data_size <= available:
            available = self.data_size
        return available // self.sample_width

    def read(self, start: int = 0, end: int | None = None) -> np.ndarray:
        total = self.samples()
        end = total if end is None else min(end, total)
        if self.data_offset is None or end <= start:
            return np.zeros(0, dtype=np.float32)
        with self.path.open("rb") as f:
            f.seek(self.data_offset + start * self.sample_width)
            raw = f.read((end - start) * self.sample_width)
        if self.sample_width == 4:
            return np.frombuffer(raw[: len(raw) // 4 * 4], dtype="<f4").astype(np.float32)
        audio = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32)
        audio *= 1 / 32768  # di tempat, tanpa salinan tambahan
        return audio


def is_pcm_wav(path: Path) -> bool:
    """WAV mono 16 kHz dari aplikasi Mac (bukan WAV sembarang dengan sample rate/kanal lain)."""
    wav = GrowingWav(path)
    try:
        found = wav._find_data()
    except (OSError, struct.error):
        return False
    return found and wav.channels == 1 and wav.sample_rate == 16000 and wav.sample_width in (2, 4)
