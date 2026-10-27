import json
from datetime import datetime
from types import SimpleNamespace

import numpy as np
import pytest
import soundfile as sf
from docx import Document

from meeting_notes.config import Settings
from meeting_notes.exporter import MeetingInfo, render_markdown, write_docx
from meeting_notes.glossary import Glossary, apply_corrections
from meeting_notes.pipeline import process_recording
from meeting_notes.recorder import mix_tracks
from meeting_notes import summarizer as summarizer_module
from meeting_notes.summarizer import (
    ActionItem,
    AgendaItem,
    ClaudeCodeSummarizer,
    Correction,
    MeetingSummary,
    Summarizer,
    make_summarizer,
)
from meeting_notes.transcriber import (
    Segment,
    Transcriber,
    chunk_bounds,
    clean_segments,
    collapse_repeats,
    normalize_loudness,
    format_timestamp,
    to_paragraphs,
)

SEGMENTS = [Segment(0, 4, "Oke kita mulai meeting-nya."), Segment(65, 70, "Budi follow up ke vendor Jumat.")]
SUMMARY = MeetingSummary(
    corrections=[],
    glossary_terms=["Budi", "vendor"],
    title="Sinkronisasi Vendor",
    executive_summary="Tim membahas progres vendor.",
    participants=["Budi", "Sari"],
    agenda=[
        AgendaItem(topic="Progres vendor", start_time="00:00", points=["Vendor terlambat 2 minggu"],
                   decisions=["Ganti jadwal rilis"]),
        AgendaItem(topic="Budget", start_time="01:05", points=["Budget belum disetujui"], decisions=[]),
    ],
    action_items=[ActionItem(task="Follow up ke vendor", owner="Budi", deadline="Jumat")],
    open_questions=[],
    highlights=[],
)
INFO = MeetingInfo(started_at=datetime(2026, 10, 27, 9, 30), duration_seconds=3725)


def test_format_timestamp():
    assert format_timestamp(65) == "01:05"
    assert format_timestamp(3725) == "01:02:05"


def test_render_markdown_with_summary():
    md = render_markdown(INFO, SEGMENTS, SUMMARY)
    assert md.startswith("# Sinkronisasi Vendor")
    assert "**Durasi:** 01:02:05" in md
    assert "**Peserta:** Budi, Sari" in md
    assert "## Keputusan Utama\n\n- Ganti jadwal rilis" in md
    assert "| 1 | Follow up ke vendor | Budi | Jumat |" in md
    assert "### 1. Progres vendor `00:00`" in md
    assert "### 2. Budget `01:05`" in md
    assert "## Pertanyaan Terbuka\n\n- -" in md
    # Ringkasan di atas, transkrip lengkap di lampiran paling bawah.
    assert md.index("## Ringkasan Eksekutif") < md.index("## Lampiran: Transkrip Lengkap")
    assert "**[01:05]** Budi follow up ke vendor Jumat." in md


def test_render_markdown_transcript_only():
    md = render_markdown(INFO, SEGMENTS, None, note="Tanpa ringkasan")
    assert md.startswith("# Rapat 27-10-2026")
    assert "> ⚠️ Tanpa ringkasan" in md
    assert "## Ringkasan" not in md


def test_write_docx(tmp_path):
    path = write_docx(tmp_path / "notes.docx", INFO, SEGMENTS, SUMMARY)
    doc = Document(path)
    text = "\n".join(p.text for p in doc.paragraphs)
    assert "Sinkronisasi Vendor" in text and "Lampiran: Transkrip Lengkap" in text
    assert "1. Progres vendor (00:00)" in text
    assert [c.text for c in doc.tables[0].rows[1].cells] == ["1", "Follow up ke vendor", "Budi", "Jumat"]
    assert "Meeting Notes v" in doc.sections[0].footer.paragraphs[0].text


def test_mix_tracks_handles_different_lengths(tmp_path):
    sr = 16000
    sf.write(tmp_path / "a.wav", np.full(sr, 0.25, dtype="float32"), sr, subtype="PCM_16")
    sf.write(tmp_path / "b.wav", np.full(sr // 2, 0.25, dtype="float32"), sr, subtype="PCM_16")
    out = mix_tracks([tmp_path / "a.wav", tmp_path / "b.wav"], tmp_path / "mix.wav", sr, blocksize=3000)
    data, _ = sf.read(out)
    assert len(data) == sr
    assert np.allclose(data[: sr // 2], 0.5, atol=1e-3)
    assert np.allclose(data[sr // 2 :], 0.25, atol=1e-3)


def test_to_paragraphs_merges_short_segments():
    segs = [Segment(0, 2, "Oke"), Segment(2.5, 4, "kita mulai."), Segment(10, 12, "Topik berikutnya.")]
    assert to_paragraphs(segs) == [Segment(0, 4, "Oke kita mulai."), Segment(10, 12, "Topik berikutnya.")]
    long = [Segment(i, i + 1, "x" * 300) for i in range(4)]
    assert len(to_paragraphs(long)) == 2


def test_clean_segments_drops_hallucinations_and_repeats():
    segs = [
        Segment(0, 1, "Halo semua."),
        Segment(1, 2, "Terima kasih telah menonton!"),
        Segment(2, 3, "Kita bahas budget."),
        Segment(3, 4, "Kita bahas budget."),
        Segment(4, 5, "..."),
    ]
    assert [s.text for s in clean_segments(segs)] == ["Halo semua.", "Kita bahas budget."]


def test_collapse_repeats_when_whisper_gets_stuck():
    stuck = "yang mengalokasikan dan " + "mengalokasikan dan " * 40
    assert collapse_repeats(stuck) == "yang mengalokasikan dan "
    assert collapse_repeats("ya ya ya ya ya") == "ya"
    # Pengulangan wajar dalam percakapan tidak diubah.
    assert collapse_repeats("oke oke kita mulai, sangat sangat penting") == "oke oke kita mulai, sangat sangat penting"
    loop = [Segment(0, 30, "aku sempat " + "mengecek dan " * 30)]
    assert clean_segments(loop)[0].text == "aku sempat mengecek dan"


def test_chunk_bounds_cut_at_quietest_point():
    sr = 100
    audio = np.ones(sr * 25, dtype="float32")
    audio[int(sr * 8.5): int(sr * 8.7)] = 0  # jeda sunyi sebelum batas 10 detik
    bounds = chunk_bounds(audio, sr=sr, chunk_seconds=10, search_seconds=3)
    assert bounds[0][0] == 0 and bounds[-1][1] == len(audio)
    assert 850 <= bounds[0][1] <= 870
    assert all(a[1] == b[0] for a, b in zip(bounds, bounds[1:], strict=False))


class FakeEngine:
    def __init__(self):
        self.calls = 0

    def transcribe(self, audio, prompt):
        self.calls += 1
        return [Segment(0.5, 1.0, f"potongan {self.calls}")]


def test_transcriber_offsets_chunks_and_skips_silence():
    transcriber = Transcriber(engine="faster-whisper", chunk_seconds=2)
    transcriber.engine = FakeEngine()
    audio = np.concatenate([np.full(32000, 0.1), np.zeros(32000), np.full(16000, 0.1)]).astype("float32")
    progress = []
    segments = transcriber.transcribe(audio, progress.append)
    # Potongan: [0-1.05s] [1.05-2.1s] [2.1-3.15s sunyi, dilewati] [3.15-5s]
    assert transcriber.engine.calls == 3
    assert [s.text for s in segments] == ["potongan 1", "potongan 2", "potongan 3"]
    assert segments[0].start == 0.5
    assert segments[-1].start == 50400 / 16000 + 0.5
    assert progress[-1] == 1.0


class FakeTranscriber:
    def transcribe(self, audio, on_progress=None):
        return SEGMENTS


def _audio(tmp_path):
    path = tmp_path / "meeting.wav"
    sf.write(path, np.zeros(16000, dtype="float32"), 16000)
    return path


def _no_api_key(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_AUTH_TOKEN", raising=False)


def test_pipeline_without_any_summarizer_saves_transcript(tmp_path, monkeypatch):
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    settings = Settings(output_dir=tmp_path / "out")
    result = process_recording(_audio(tmp_path), settings, INFO.started_at, lambda _: None, FakeTranscriber())
    assert result.markdown_path.name == "2026-10-27_0930_rapat.md"
    assert result.docx_path.exists()
    assert "Claude Code belum terpasang" in result.note


def test_make_summarizer_prefers_subscription_without_api_key(monkeypatch):
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: "/usr/bin/claude")
    chosen, reason = make_summarizer(Settings(summarizer="auto"))
    assert isinstance(chosen, ClaudeCodeSummarizer) and reason is None


def test_make_summarizer_uses_api_when_key_set(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: "/usr/bin/claude")
    assert isinstance(make_summarizer(Settings(summarizer="auto"))[0], Summarizer)
    assert isinstance(make_summarizer(Settings(summarizer="claude-code"))[0], ClaudeCodeSummarizer)
    assert make_summarizer(Settings(summarizer="none"))[0] is None


def test_claude_code_summarizer(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "should-not-leak")
    calls = {}

    def fake_run(cmd, **kwargs):
        calls.update(cmd=cmd, **kwargs)
        out = {"is_error": False, "structured_output": SUMMARY.model_dump()}
        return SimpleNamespace(returncode=0, stdout=json.dumps(out), stderr="")

    monkeypatch.setattr(summarizer_module.subprocess, "run", fake_run)
    result = ClaudeCodeSummarizer("claude", model="sonnet").summarize("[00:00] halo", ["VoIP"])
    assert result == SUMMARY
    assert calls["cmd"][:2] == ["claude", "-p"]
    assert calls["cmd"][-2:] == ["--model", "sonnet"]
    assert "ANTHROPIC_API_KEY" not in calls["env"]
    assert calls["input"].startswith("<kamus>\nVoIP\n</kamus>")
    assert calls["input"].endswith("<transkrip>\n[00:00] halo\n</transkrip>")


def test_claude_code_summarizer_reports_login_error(monkeypatch):
    out = {"is_error": True, "result": "Not logged in · Please run /login"}
    monkeypatch.setattr(
        summarizer_module.subprocess, "run",
        lambda cmd, **kw: SimpleNamespace(returncode=1, stdout=json.dumps(out), stderr=""),
    )
    with pytest.raises(RuntimeError, match="Please run /login"):
        ClaudeCodeSummarizer("claude").summarize("x")


def test_pipeline_with_summary(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    monkeypatch.setattr(Summarizer, "summarize", lambda self, transcript, glossary=(), marks=(): SUMMARY)
    settings = Settings(output_dir=tmp_path / "out")
    result = process_recording(_audio(tmp_path), settings, INFO.started_at, lambda _: None, FakeTranscriber())
    assert result.markdown_path.name == "2026-10-27_0930_sinkronisasi-vendor.md"
    assert result.note is None


def test_render_lists_corrections():
    md = render_markdown(INFO, SEGMENTS, SUMMARY, corrections={("girlfriend", "frontend"): 2})
    assert "## Lampiran: Koreksi Otomatis" in md
    assert "| girlfriend | frontend | 2 |" in md


def test_apply_corrections():
    text = "Yang bikin start girlfriend-nya doang. PoIP dari Daily Banking. Girlfriend saya bukan programmer."
    fixed, counts = apply_corrections(
        text, [("start girlfriend", "start frontend"), ("PoIP", "VoIP"), ("", "x"), ("ip", "ip")]
    )
    assert fixed == "Yang bikin start frontend-nya doang. VoIP dari Daily Banking. Girlfriend saya bukan programmer."
    assert counts == {("start girlfriend", "start frontend"): 1, ("PoIP", "VoIP"): 1}
    # Kata utuh saja: "api" tidak boleh mengganti bagian dari "kapital".
    assert apply_corrections("api dan kapital", [("api", "API")])[0] == "API dan kapital"
    # Koreksi huruf besar/kecil dicocokkan persis.
    assert apply_corrections("voip dan Voip", [("voip", "VoIP")])[0] == "VoIP dan Voip"


def test_glossary_learns_and_prioritizes_recent_terms(tmp_path):
    path = tmp_path / "kamus.txt"
    g = Glossary(path)
    g.merge(["VoIP", "frontend"])
    g.save()
    g = Glossary(path)
    g.merge(["Daily Banking", "voip", " "])
    assert g.terms == ["Daily Banking", "voip", "frontend"]
    g.save()
    assert path.read_text(encoding="utf-8").startswith("# Kamus")
    assert Glossary(path).terms == ["Daily Banking", "voip", "frontend"]
    assert g.whisper_hint(max_chars=30) == "Daily Banking, voip"


def test_base_glossary_fills_after_learned_terms(tmp_path):
    base = tmp_path / "dasar.txt"
    base.write_text("# komentar\nsetor tunai\nVoIP\nteller\n", encoding="utf-8")
    g = Glossary(tmp_path / "kamus.txt", base_path=base)
    g.merge(["Daily Banking", "voip"])
    assert g.all_terms == ["Daily Banking", "voip", "setor tunai", "teller"]
    g.save()
    # Kamus dasar tidak ikut tersimpan ke kamus pribadi.
    assert Glossary(tmp_path / "kamus.txt", base_path=None).terms == ["Daily Banking", "voip"]
    # Kamus dasar bawaan benar-benar ada dan berisi istilah dari temuan QA.
    bundled = Glossary(tmp_path / "kosong.txt").all_terms
    assert {"setor tunai", "frontend", "VoIP", "nasabah"} <= set(bundled)
    assert len(Glossary(tmp_path / "kosong.txt").whisper_hint()) <= 400


def test_normalize_loudness_boosts_quiet_speech_only():
    quiet = (np.sin(np.arange(16000 * 2) / 5) * 0.02).astype("float32")  # butuh gain ~7x
    boosted = normalize_loudness(quiet)
    assert np.abs(boosted).max() == pytest.approx(0.1 * np.sqrt(2), rel=0.05)
    assert np.abs(normalize_loudness(quiet * 0.0001)).max() <= 0.1 * np.sqrt(2) * 1.01  # gain dibatasi 10x
    normal = (np.sin(np.arange(16000) / 5) * 0.14).astype("float32")
    assert normalize_loudness(normal) is normal  # sudah cukup keras, tidak diubah
    silence = np.zeros(16000, dtype="float32")
    assert normalize_loudness(silence) is silence


def test_transcriber_prompt_includes_vocabulary():
    t = Transcriber(engine="faster-whisper")
    assert "Istilah" not in t.prompt()
    t.vocabulary = "VoIP, frontend"
    assert t.prompt().endswith("Istilah: VoIP, frontend.")


def test_pipeline_applies_corrections_and_updates_glossary(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    summary = SUMMARY.model_copy(update={
        "corrections": [Correction(wrong="follow up ke vendor", correct="follow up ke vendor VoIP")],
        "glossary_terms": ["VoIP"],
    })
    seen = {}

    def fake_summarize(self, transcript, glossary=(), marks=()):
        seen["glossary"] = list(glossary)
        return summary

    monkeypatch.setattr(Summarizer, "summarize", fake_summarize)
    settings = Settings(output_dir=tmp_path / "out")
    settings.output_dir.mkdir()
    settings.glossary_path.write_text("Daily Banking\n", encoding="utf-8")
    transcriber = FakeTranscriber()
    result = process_recording(_audio(tmp_path), settings, INFO.started_at, lambda _: None, transcriber)
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "Budi follow up ke vendor VoIP Jumat." in md
    assert "| follow up ke vendor | follow up ke vendor VoIP | 1 |" in md
    assert seen["glossary"][0] == "Daily Banking" and "setor tunai" in seen["glossary"]
    assert transcriber.vocabulary.startswith("Daily Banking, setor tunai")
    assert Glossary(settings.glossary_path).terms == ["VoIP", "Daily Banking"]


def test_summarizer_request(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    calls = {}

    def fake_parse(**kwargs):
        calls.update(kwargs)
        return SimpleNamespace(stop_reason="end_turn", parsed_output=SUMMARY)

    summarizer = Summarizer()
    monkeypatch.setattr(summarizer.client.beta.messages, "parse", fake_parse)
    assert summarizer.summarize("[00:00] halo") is SUMMARY
    assert calls["model"] == "claude-opus-5-5"
    assert calls["output_format"] is MeetingSummary
    expected = "<kamus>\n(masih kosong)\n</kamus>\n\n<transkrip>\n[00:00] halo\n</transkrip>"
    assert calls["messages"][0]["content"] == expected


def test_highlights_in_input_and_export():
    from meeting_notes.summarizer import Highlight, _build_input

    text = _build_input("[00:00] halo", ["VoIP"], [750.4, 3725])
    assert text.endswith("<momen_penting>\n12:30, 01:02:05\n</momen_penting>")
    assert "<momen_penting>" not in _build_input("[00:00] halo", [])
    summary = SUMMARY.model_copy(update={"highlights": [Highlight(time="12:30", summary="Rilis diundur.")]})
    md = render_markdown(INFO, SEGMENTS, summary)
    assert "## Momen Penting\n\n- `12:30` Rilis diundur." in md
    assert md.index("## Momen Penting") < md.index("## Pembahasan per Agenda")


def test_cli_json_mode_for_mac_app(tmp_path, monkeypatch, capsys):
    import sys

    from meeting_notes import __main__ as cli
    from meeting_notes import pipeline

    seen = {}

    def fake_process(audio, settings, started_at, on_status, marks=()):
        seen.update(marks=marks, started_at=started_at)
        on_status("Mentranskrip... 50%")
        return pipeline.NotesResult(tmp_path / "a.md", tmp_path / "a.docx", None, "Sinkronisasi Vendor", 2, 3)

    monkeypatch.setattr(pipeline, "process_recording", fake_process)
    marks = tmp_path / "penting.json"
    marks.write_text("[12.5, 300]")
    monkeypatch.setattr(sys, "argv", ["meeting_notes", "proses", str(tmp_path / "rapat.wav"), "--json",
                                      "--penting", str(marks), "--mulai", "2026-10-27T09:30:00"])
    cli.main()
    lines = capsys.readouterr().out.strip().splitlines()
    assert lines[0] == "STATUS\tMentranskrip... 50%"
    kind, payload = lines[-1].split("\t", 1)
    assert kind == "RESULT"
    assert json.loads(payload)["title"] == "Sinkronisasi Vendor"
    assert json.loads(payload)["action_items"] == 3
    assert seen == {"marks": [12.5, 300], "started_at": datetime(2026, 10, 27, 9, 30)}
