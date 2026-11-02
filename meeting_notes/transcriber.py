"""Transkripsi audio secara lokal dengan Whisper.

Di Mac Apple Silicon (M1/M2/...) memakai mlx-whisper yang berjalan di GPU Mac; selain itu faster-whisper.
Audio diproses per potongan +-10 menit agar progres terlihat dan rapat 4 jam tidak membebani memori.
"""

import platform
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
CHUNK_SECONDS = 600
# Potongan dicari di titik paling sunyi dalam 20 detik terakhir agar kalimat tidak terpotong.
CUT_SEARCH_SECONDS = 20
SILENCE_RMS = 1e-3
# Tingkat suara (lihat speech_level) minimum agar sebuah jalur rekaman dianggap berisi ucapan.
SPEECH_LEVEL = 3e-3
# Model Whisper. "auto" memilih large-v3 penuh (lebih akurat untuk bicara cepat/belibet) bila Mac kuat, karena
# transkripsi berjalan di latar belakang selama rapat sehingga lambatnya tidak terasa; selain itu turbo.
FAST_MODEL = "large-v3-turbo"
ACCURATE_MODEL = "large-v3"
ACCURATE_MIN_RAM_GB = 16
# Jeda hening yang lebih panjang dari ini dipangkas sebelum ditranskripsi.
MAX_PAUSE_SECONDS = 1.5
# Label jalur rekaman terpisah dari aplikasi Mac.
MIC_LABEL = "Saya (mic)"
SYSTEM_LABEL = "Peserta online"

# Contoh gaya bicara rapat tim produk/developer. Whisper meniru ejaan dan gaya prompt, jadi kalimat alami
# dengan istilah teknis dan singkatan (FE, BE, PR) jauh lebih efektif daripada daftar kata saja. Diletakkan
# paling akhir karena Whisper memotong prompt yang terlalu panjang dari depan.
BASE_PROMPT = (
    "Rapat kerja tim produk digital dalam Bahasa Indonesia campur English. "
    "Oke, FE sama BE sudah siap, datanya di-fetch dari API, asetnya di-bundling, desain UI/UX dari Figma. "
    "Fiturnya pakai feature flag, flagging-nya bertahap. PR-nya di-review dan di-merge, "
    "lalu deploy ke staging buat SIT dan UAT sebelum production."
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
    # Label pembicara dari mesin cloud (mis. "speaker_0"); Whisper lokal tidak mengisinya.
    speaker: str | None = None


def format_timestamp(seconds: float) -> str:
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def segments_to_text(segments: list[Segment]) -> str:
    return "\n".join(
        f"[{format_timestamp(s.start)}] {s.speaker + ': ' if s.speaker else ''}{s.text}" for s in segments
    )


def label_speakers(segments: list[Segment]) -> list[Segment]:
    """Ganti label mentah mesin cloud (speaker_0, speaker_A, ...) menjadi Pembicara 1, 2, ... sesuai urutan muncul."""
    names: dict[str, str] = {}
    for s in segments:
        if s.speaker and s.speaker not in names:
            names[s.speaker] = f"Pembicara {len(names) + 1}"
    return [Segment(s.start, s.end, s.text, names.get(s.speaker) if s.speaker else None) for s in segments]


def to_paragraphs(segments: list[Segment], max_gap: float = 2.0, max_chars: int = 700) -> list[Segment]:
    """Gabungkan potongan pendek Whisper menjadi paragraf; jeda panjang memulai paragraf baru."""
    paragraphs: list[Segment] = []
    for seg in segments:
        last = paragraphs[-1] if paragraphs else None
        same_speaker = last is not None and last.speaker == seg.speaker
        if last and same_speaker and seg.start - last.end <= max_gap and len(last.text) + len(seg.text) < max_chars:
            paragraphs[-1] = Segment(last.start, seg.end, f"{last.text} {seg.text}", seg.speaker)
        else:
            paragraphs.append(seg)
    return paragraphs


def _normalize(text: str) -> str:
    return re.sub(r"[^\w\s]", "", text.lower()).strip()


# Frasa 1-6 kata yang muncul 4 kali atau lebih berturut-turut ("mengalokasikan dan mengalokasikan dan ...").
_REPEAT = re.compile(r"\b(\w+(?:\W+\w+){0,5}?)(?:\W+\1\b){3,}", re.IGNORECASE)


def collapse_repeats(text: str) -> str:
    """Whisper kadang 'macet' mengulang frasa saat pembicara diam; sisakan satu saja."""
    return _REPEAT.sub(r"\1", text)


def clean_segments(segments: list[Segment]) -> list[Segment]:
    """Buang halusinasi Whisper dan baris yang terulang beruntun."""
    result: list[Segment] = []
    for seg in segments:
        seg = Segment(seg.start, seg.end, collapse_repeats(seg.text).strip(), seg.speaker)
        norm = _normalize(seg.text)
        if not norm:
            continue
        if any(h in norm and len(norm) < len(h) + 15 for h in HALLUCINATIONS):
            continue
        if result and _normalize(result[-1].text) == norm:
            continue
        result.append(seg)
    return result


def speech_level(audio: np.ndarray) -> float:
    """Volume bagian paling keras (persentil 95 RMS per 100 ms), sehingga jeda sunyi tidak ikut terhitung."""
    frame = SAMPLE_RATE // 10
    usable = len(audio) // frame * frame
    if usable == 0:
        return 0.0
    rms = np.sqrt((audio[:usable].reshape(-1, frame) ** 2).mean(axis=1))
    return float(np.percentile(rms, 95))


def normalize_loudness(audio: np.ndarray, target_rms: float = 0.1, max_gain: float = 10.0) -> np.ndarray:
    """Samakan volume ucapan ke tingkat yang nyaman untuk Whisper.

    Suara pelan (mic jauh, pembicara bersuara kecil) dikuatkan hingga max_gain kali.
    """
    level = speech_level(audio)
    if level < 1e-4:
        return audio
    gain = min(target_rms / level, max_gain)
    if 0.8 < gain < 1.25:
        return audio
    return np.clip(audio * gain, -1.0, 1.0).astype(np.float32)


def _echoes(seg: Segment, others: list[Segment], threshold: float = 0.6) -> bool:
    """Apakah seg sebagian besar mengulang kata-kata dari others pada waktu yang hampir sama."""
    words = _normalize(seg.text).split()
    near = [o.text for o in others if o.start <= seg.end + 2 and o.end >= seg.start - 2]
    reference = _normalize(" ".join(near)).split()
    if not words or not reference:
        return False
    matcher = SequenceMatcher(None, words, reference, autojunk=False)
    return sum(block.size for block in matcher.get_matching_blocks()) / len(words) >= threshold


def merge_tracks(system: list[Segment], mic: list[Segment]) -> list[Segment]:
    """Gabungkan transkrip jalur meeting dan jalur mic sesuai waktu.

    Saat memakai speaker, mic ikut menangkap suara peserta online; potongan mic yang mengulang ucapan di jalur
    meeting pada waktu yang sama dibuang agar tidak tercatat dua kali.
    """
    kept = [s for s in mic if not _echoes(s, system)]
    return sorted(system + kept, key=lambda s: s.start)


def speech_spans(audio: np.ndarray, sr: int = SAMPLE_RATE, max_pause: float = MAX_PAUSE_SECONDS,
                 pad: float = 0.3) -> list[tuple[int, int]]:
    """Rentang sampel yang berisi suara; jeda pendek (<= max_pause) tetap disertakan agar kalimat utuh.

    Ambang mengikuti derau latar rekaman itu sendiri (2x derau ruangan), sehingga mic yang berisik maupun
    audio meeting digital yang hening total sama-sama tertangani. Ambang dibatasi 30% dari bagian terkeras
    agar orang yang bicara tanpa jeda (derau latar = suaranya sendiri) tidak ikut terpangkas.
    """
    frame = sr // 10
    n = len(audio) // frame
    if n == 0:
        return []
    rms = np.sqrt((audio[: n * frame].reshape(-1, frame) ** 2).mean(axis=1))
    floor, loud = np.percentile(rms, [20, 95])
    threshold = max(1.5e-3, min(float(floor) * 2, float(loud) * 0.3))
    active = np.flatnonzero(rms >= threshold)
    if active.size == 0:
        return []
    spans: list[list[int]] = []
    gap_frames = int(max_pause * 10)
    for i in active:
        if spans and i - spans[-1][1] <= gap_frames:
            spans[-1][1] = i
        else:
            spans.append([i, i])
    pad_samples = int(pad * sr)
    return [(max(0, a * frame - pad_samples), min(len(audio), (b + 1) * frame + pad_samples)) for a, b in spans]


class Condensed:
    """Audio dengan jeda hening panjang dipangkas, beserta peta waktu kembali ke rekaman asli.

    Whisper bekerja per jendela 30 detik; hening tidak perlu ditranskripsi. Memangkasnya mempercepat
    transkripsi (terutama jalur mic saat pengguna lebih banyak mendengarkan) dan mencegah halusinasi.
    """

    GAP = 0.2  # detik hening pemisah antar-potongan agar kata tidak menempel

    def __init__(self, audio: np.ndarray, sr: int = SAMPLE_RATE):
        self.sr = sr
        self.map: list[tuple[float, float, float]] = []  # (mulai di audio ringkas, mulai asli, durasi)
        parts, position = [], 0.0
        silence = np.zeros(int(self.GAP * sr), dtype=np.float32)
        for start, end in speech_spans(audio, sr):
            if parts:
                parts.append(silence)
                position += self.GAP
            parts.append(audio[start:end])
            self.map.append((position, start / sr, (end - start) / sr))
            position += (end - start) / sr
        self.audio = np.concatenate(parts).astype(np.float32) if parts else np.zeros(0, dtype=np.float32)

    @property
    def seconds(self) -> float:
        return len(self.audio) / self.sr

    def original_time(self, t: float) -> float:
        for cond_start, orig_start, duration in reversed(self.map):
            if t >= cond_start:
                return orig_start + min(t - cond_start, duration)
        return self.map[0][1] if self.map else t


def physical_ram_gb() -> float:
    try:
        import os

        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024**3
    except (ValueError, OSError, AttributeError):
        return 0.0


def resolve_model(name: str) -> str:
    """'auto' -> large-v3 di Mac Apple Silicon dengan RAM >= 16 GB, selain itu large-v3-turbo."""
    if name != "auto":
        return name
    return ACCURATE_MODEL if is_apple_silicon() and physical_ram_gb() >= ACCURATE_MIN_RAM_GB else FAST_MODEL


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
            # Lewati bagian sunyi yang memicu halusinasi (butuh word_timestamps).
            word_timestamps=True, hallucination_silence_threshold=2.0,
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
            # Lewati bagian sunyi yang memicu halusinasi (butuh word_timestamps).
            word_timestamps=True, hallucination_silence_threshold=2.0,
        )
        return [
            Segment(s["start"], s["end"], s["text"].strip())
            for s in result["segments"]
            if not (s.get("no_speech_prob", 0) > 0.6 and s.get("avg_logprob", 0) < -1.0)
        ]


class Transcriber:
    def __init__(
        self, model_size: str = "auto", language: str | None = "id", engine: str = "auto",
        chunk_seconds: int = CHUNK_SECONDS,
    ):
        self.chunk_seconds = chunk_seconds
        self.language = language
        # Istilah dari kamus otomatis, dipakai sebagai petunjuk ejaan untuk Whisper.
        self.vocabulary = ""
        self.use_mlx = engine == "mlx" or (engine == "auto" and is_apple_silicon())
        self.model_size = ""
        self.use_model(resolve_model(model_size))

    def use_model(self, model_size: str) -> None:
        """Ganti model (mis. turun ke turbo bila Mac tidak mampu mengejar rapat yang sedang berjalan)."""
        if model_size != self.model_size:
            self.model_size = model_size
            self.engine = (_MlxEngine if self.use_mlx else _FasterWhisperEngine)(model_size, self.language)

    def download(self) -> None:
        """Unduh model (sekali saja) tanpa memuatnya ke memori."""
        self.engine.download()

    def prompt(self) -> str:
        if not self.vocabulary:
            return BASE_PROMPT
        # Whisper hanya memakai +-223 token terakhir dari prompt. Istilah terpenting (urutan pertama di kamus)
        # ditaruh paling dekat ke akhir, sehingga bila prompt kepanjangan yang terpotong istilah yang kurang penting.
        terms = ", ".join(reversed(self.vocabulary.split(", ")))
        return f"Istilah: {terms}. {BASE_PROMPT}"

    def transcribe_chunk(self, chunk: np.ndarray, offset: float = 0.0) -> list[Segment]:
        """Transkripsi satu potongan (tanpa membersihkan); waktu dihitung dari awal rekaman."""
        condensed = Condensed(chunk)
        if condensed.seconds < 0.5:
            return []
        return [
            Segment(condensed.original_time(s.start) + offset, condensed.original_time(s.end) + offset, s.text)
            for s in self.engine.transcribe(normalize_loudness(condensed.audio), self.prompt())
        ]

    def transcribe(self, audio: np.ndarray, on_progress: Callable[[float], None] | None = None,
                   offset: float = 0.0) -> list[Segment]:
        bounds = chunk_bounds(audio, chunk_seconds=self.chunk_seconds)
        segments: list[Segment] = []
        for i, (start, end) in enumerate(bounds):
            segments += self.transcribe_chunk(audio[start:end], offset + start / SAMPLE_RATE)
            if on_progress:
                on_progress((i + 1) / len(bounds))
        return clean_segments(segments)
