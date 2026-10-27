"""Uji tanding mesin transkripsi pada potongan rekaman yang sama, hasilnya ditampilkan berdampingan.

    python -m meeting_notes bandingkan rekaman.wav --mulai 120 --durasi 300
"""

import html
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import soundfile as sf

from .cloud_stt import PROVIDERS, Provider, transcribe_with_fallback
from .config import Settings
from .glossary import Glossary
from .transcriber import SAMPLE_RATE, Segment, Transcriber, clean_segments, format_timestamp, load_audio


@dataclass
class Result:
    name: str
    seconds: float
    segments: list[Segment]
    error: str | None = None
    usd: float | None = None


def _run(name: str, fn, usd: float | None) -> Result:
    started = time.monotonic()
    try:
        segments = fn()
        return Result(name, time.monotonic() - started, segments, usd=usd)
    except Exception as exc:  # noqa: BLE001 - satu mesin gagal tidak menghentikan yang lain
        return Result(name, time.monotonic() - started, [], error=str(exc)[:300])


def compare(audio_path: Path, settings: Settings, start: float = 0, duration: float = 300,
            include_local: bool = True) -> Path:
    audio = load_audio(audio_path)
    clip = audio[int(start * SAMPLE_RATE): int((start + duration) * SAMPLE_RATE)]
    if clip.size == 0:
        raise ValueError("Potongan kosong: periksa --mulai dan --durasi.")
    clip_seconds = len(clip) / SAMPLE_RATE
    outdir = settings.output_dir / "perbandingan" / f"{datetime.now():%Y-%m-%d_%H%M%S}"
    outdir.mkdir(parents=True, exist_ok=True)
    clip_path = outdir / "potongan.wav"
    sf.write(clip_path, clip, SAMPLE_RATE, subtype="PCM_16")

    keyterms = Glossary(settings.glossary_path).all_terms
    providers: list[Provider] = [cls() for cls in PROVIDERS.values()]
    active = [p for p in providers if p.api_key]
    skipped = [p for p in providers if not p.api_key]
    print(f"Potongan {format_timestamp(clip_seconds)} disimpan di {clip_path}")
    print("Mesin:", ", ".join([p.name for p in active] + (["Whisper lokal"] if include_local else [])) or "-")
    for p in skipped:
        print(f"  (lewati {p.name}: {p.env_key} belum diisi di .env)")

    jobs = [
        (p.name, lambda p=p: transcribe_with_fallback(p, clip_path, keyterms), p.usd_per_hour * clip_seconds / 3600)
        for p in active
    ]
    with ThreadPoolExecutor(max_workers=len(jobs) or 1) as pool:
        futures = [pool.submit(_run, *job) for job in jobs]
        results = []
        if include_local:
            transcriber = Transcriber(settings.whisper_model, settings.language, settings.whisper_engine)
            transcriber.vocabulary = Glossary(settings.glossary_path).whisper_hint()
            print("Whisper lokal berjalan...")
            results.append(_run(f"Whisper lokal ({settings.whisper_model})",
                                lambda: transcriber.transcribe(clip), 0.0))
        results = [f.result() for f in futures] + results
    for r in results:
        status = f"GAGAL: {r.error}" if r.error else f"{len(r.segments)} segmen"
        print(f"  {r.name}: {r.seconds:.0f} detik, {status}")

    report = outdir / "perbandingan.html"
    report.write_text(render_html(audio_path, start, clip_seconds, results), encoding="utf-8")
    return report


def render_html(audio_path: Path, start: float, clip_seconds: float, results: list[Result]) -> str:
    columns = []
    for r in results:
        cost = "gratis (lokal)" if r.usd == 0 else (f"± ${r.usd:.3f}" if r.usd is not None else "-")
        head = (f"<h2>{html.escape(r.name)}</h2><p class=meta>{r.seconds:.0f} detik proses · {cost}</p>")
        if r.error:
            body = f"<p class=err>Gagal: {html.escape(r.error)}</p>"
        else:
            body = "".join(
                f"<p><span class=ts>[{format_timestamp(start + s.start)}]</span> "
                + (f"<span class=spk>{html.escape(s.speaker)}</span> " if s.speaker else "")
                + f"{html.escape(s.text)}</p>"
                for s in clean_segments(r.segments)
            ) or "<p class=meta>(kosong)</p>"
        columns.append(f"<section>{head}{body}</section>")
    return f"""<!doctype html><html lang=id><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1"><title>Perbandingan Transkripsi</title>
<style>
:root{{--bg:#f6f7f9;--card:#fff;--fg:#1f2329;--muted:#6b7280;--accent:#2563eb;--err:#dc2626}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111316;--card:#1b1e23;--fg:#e8eaed;--muted:#9aa0a6;
--accent:#60a5fa;--err:#f87171}}}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,system-ui,sans-serif}}
main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}}
section{{background:var(--card);border-radius:14px;padding:14px 16px;max-height:80vh;overflow:auto}}
h1{{font-size:20px;margin:0 0 4px}} h2{{font-size:16px;margin:0}}
.meta,.ts,.spk{{color:var(--muted);font-size:13px}} .spk{{color:var(--accent)}} .err{{color:var(--err)}}
</style></head><body>
<h1>Perbandingan Transkripsi</h1>
<p class=meta>{html.escape(audio_path.name)} · mulai {format_timestamp(start)} · durasi {format_timestamp(clip_seconds)}
· Dengarkan <code>potongan.wav</code> di folder yang sama, lalu nilai kolom mana yang paling benar.</p>
<main>{"".join(columns)}</main></body></html>
"""


def open_report(path: Path) -> None:
    webbrowser.open(path.resolve().as_uri())
