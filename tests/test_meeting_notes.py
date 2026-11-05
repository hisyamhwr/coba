import itertools
import json
from datetime import datetime
from types import SimpleNamespace

import numpy as np
import pytest
import soundfile as sf
from docx import Document

from meeting_notes.config import Settings
from meeting_notes.exporter import MeetingInfo, render_markdown, write_docx
from meeting_notes.glossary import BASE_CORRECTIONS_PATH, Glossary, apply_corrections, read_corrections
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
    is_repetition,
    normalize_loudness,
    remove_rumble,
    Condensed,
    format_timestamp,
    merge_tracks,
    resolve_model,
    speech_spans,
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
    risks=["Vendor bisa terlambat lagi bila kontrak belum diteken"],
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


def test_repetition_hallucination_on_silence_is_dropped_entirely():
    # Hening/derau: Whisper menghasilkan "Pada Pada Pada ..." (dilaporkan dari transkrip live 3.4.5).
    stuck = [Segment(0, 9, "Pada " * 30), Segment(9, 18, "Pada. Pada, pada pada"),
             Segment(18, 20, "Kemarin kita bahas flagging")]
    assert [s.text for s in clean_segments(stuck)] == ["Kemarin kita bahas flagging"]
    # Ucapan wajar yang pendek atau mengulang sedikit tetap ada.
    assert is_repetition("ya ya oke ya") is False
    assert is_repetition("oke oke kita mulai") is False


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
    # "Ucapan" berupa nada 300 Hz (RMS 0,1); DC konstan tidak dipakai karena dibuang filter dengung.
    tone = lambda n: 0.1 * np.sqrt(2) * np.sin(2 * np.pi * 300 * np.arange(n) / 16000)
    audio = np.concatenate([tone(32000), np.zeros(32000), tone(16000)]).astype("float32")
    progress = []
    segments = transcriber.transcribe(audio, progress.append)
    # Potongan: [0-1.05s] [1.05-2.1s] [2.1-3.15s sunyi, dilewati] [3.15-5s]
    assert transcriber.engine.calls == 3
    assert [s.text for s in segments] == ["potongan 1", "potongan 2", "potongan 3"]
    assert segments[0].start == 0.5
    # Potongan terakhir dimulai 3,15 s, suara baru mulai 4,0 s: hening di depannya dipangkas (sisa jeda 0,3 s
    # sebelum suara + penyelarasan 100 ms), lalu waktu dari Whisper dipetakan kembali ke rekaman asli.
    assert segments[-1].start == pytest.approx(4.15)
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
    # Word tidak dibuat bila tidak dicentang (default).
    assert result.docx_path is None
    assert list(settings.output_dir.glob("*.docx")) == []
    assert "Claude Code belum terpasang" in result.note


def test_pipeline_creates_docx_when_checked(tmp_path, monkeypatch):
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    settings = Settings(output_dir=tmp_path / "out", export_docx=True)
    result = process_recording(_audio(tmp_path), settings, INFO.started_at, lambda _: None, FakeTranscriber())
    assert result.docx_path == settings.output_dir / "2026-10-27_0930_rapat.docx"
    assert result.docx_path.exists()


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


def test_claude_code_summarizer_uses_effort_and_falls_back_on_old_cli(monkeypatch):
    commands = []

    def fake_run(cmd, **kwargs):
        commands.append(cmd)
        if "--effort" in cmd:  # Claude Code versi lama
            return SimpleNamespace(returncode=1, stdout="", stderr="error: unknown option '--effort'")
        out = {"is_error": False, "structured_output": SUMMARY.model_dump()}
        return SimpleNamespace(returncode=0, stdout=json.dumps(out), stderr="")

    monkeypatch.setattr(summarizer_module.subprocess, "run", fake_run)
    assert ClaudeCodeSummarizer("claude", model="sonnet", effort="medium").summarize("x") == SUMMARY
    assert commands[0][-4:] == ["--model", "sonnet", "--effort", "medium"]
    assert "--effort" not in commands[1]
    # Bawaan: Sonnet dengan effort medium (MoM rapat 1 jam +-25 detik).
    chosen = ClaudeCodeSummarizer("claude", Settings().claude_code_model, effort=Settings().claude_code_effort)
    assert (chosen.model, chosen.effort) == ("sonnet", "medium")


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
    assert {"setor tunai", "frontend", "VoIP", "nasabah", "flagging", "FE", "BE", "DS"} <= set(bundled)
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
    # Daftar istilah di depan, contoh kalimat di akhir (Whisper memotong prompt panjang dari depan).
    # Istilah terpenting (pertama di kamus) paling dekat ke akhir prompt.
    assert t.prompt().startswith("Istilah: frontend, VoIP. ")
    assert t.prompt().endswith("production.")


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
    assert transcriber.vocabulary.startswith("Daily Banking, frontend")
    assert Glossary(settings.glossary_path).terms == ["VoIP", "Daily Banking"]
    # Koreksi yang hanya menyisipkan kata tidak dipelajari untuk transkrip live (bisa menggandakan "VoIP").
    assert Glossary(settings.glossary_path).corrections == []


def test_learn_corrections_newest_first_and_skips_short(tmp_path):
    glossary = Glossary(tmp_path / "kamus.txt", base_path=None)
    glossary.learn_corrections([("legging", "flagging"), ("fe", "FE"), ("same", "same"), ("voip", "VoIP"),
                                ("ke vendor", "ke vendor VoIP")])
    glossary.learn_corrections([("Legging", "flagging"), ("di repost", "di-deploy")])
    glossary.save()
    expected = [("Legging", "flagging"), ("di repost", "di-deploy"), ("voip", "VoIP")]
    assert read_corrections(tmp_path / "koreksi.txt") == expected
    assert Glossary(tmp_path / "kamus.txt").corrections == expected


def test_base_corrections_file_is_valid():
    pairs = read_corrections(BASE_CORRECTIONS_PATH)
    assert ("legging", "flagging") in pairs
    assert all(wrong.casefold() != correct.casefold() or wrong != correct for wrong, correct in pairs)


def test_remove_rumble_keeps_speech_band():
    t = np.arange(16000 * 2) / 16000
    hum = 0.3 * np.sin(2 * np.pi * 50 * t)
    voice = 0.1 * np.sin(2 * np.pi * 300 * t)
    out = remove_rumble((hum + voice + 0.05).astype(np.float32))
    assert out.dtype == np.float32
    assert np.abs(out - voice).max() < 0.01
    clean = voice.astype(np.float32)
    assert remove_rumble(clean) is clean


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
        seen.update(marks=marks, started_at=started_at, docx=settings.export_docx)
        on_status("Mentranskrip... 50%")
        return pipeline.NotesResult(tmp_path / "a.md", tmp_path / "a.docx", None, "Sinkronisasi Vendor", 2, 3)

    monkeypatch.setattr(pipeline, "process_recording", fake_process)
    marks = tmp_path / "penting.json"
    marks.write_text("[12.5, 300]")
    monkeypatch.setattr(sys, "argv", ["meeting_notes", "proses", str(tmp_path / "rapat.wav"), "--json",
                                      "--penting", str(marks), "--mulai", "2026-10-27T09:30:00", "--docx"])
    cli.main()
    lines = capsys.readouterr().out.strip().splitlines()
    assert lines[0] == "STATUS\tMentranskrip... 50%"
    kind, payload = lines[-1].split("\t", 1)
    assert kind == "RESULT"
    assert json.loads(payload)["title"] == "Sinkronisasi Vendor"
    assert json.loads(payload)["action_items"] == 3
    assert seen == {"marks": [12.5, 300], "started_at": datetime(2026, 10, 27, 9, 30), "docx": True}


def test_merge_tracks_drops_speaker_echo_from_mic():
    system = [Segment(10, 14, "FE sama BE sudah siap untuk SIT minggu ini", "Peserta online")]
    mic = [
        Segment(2, 5, "Oke saya mulai ya", "Saya (mic)"),
        # Suara speaker yang tertangkap mic (sedikit beda tangkapan): bukan ucapan pengguna.
        Segment(10.3, 14.2, "FE sama BE sudah siap untuk SIT minggu", "Saya (mic)"),
        Segment(15, 17, "Siap, nanti saya follow up", "Saya (mic)"),
    ]
    merged = merge_tracks(system, mic)
    assert [(s.speaker, s.start) for s in merged] == [
        ("Saya (mic)", 2), ("Peserta online", 10), ("Saya (mic)", 15)]


class TrackTranscriber:
    """Mengembalikan transkrip berbeda tergantung jalur mana yang ditranskripsi (dibedakan dari volumenya)."""

    vocabulary = ""
    model_size = "large-v3-turbo"

    def __init__(self):
        self.calls = []

    def transcribe(self, audio, on_progress=None, offset=0.0):
        level = float(np.abs(audio).max())
        self.calls.append(level)
        if on_progress:
            on_progress(1.0)
        if level < 1e-3:
            return []  # hening: Whisper (dengan pemangkasan hening) tidak menghasilkan apa pun
        if level > 0.25:
            return [Segment(1, 3, "Deploy ke staging hari ini ya")]
        return [Segment(4, 6, "Siap, saya cek flagging-nya")]

    def transcribe_wav(self, reader, start=0, on_progress=None):
        return self.transcribe(reader.read(start), on_progress, offset=start / 16000)


def test_pipeline_transcribes_mic_and_meeting_tracks_separately(tmp_path, monkeypatch):
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    tone = np.sin(np.arange(16000 * 2) / 5).astype("float32")
    sf.write(tmp_path / "meeting.wav", tone * 0.4, 16000)
    sf.write(tmp_path / "sistem.wav", tone * 0.3, 16000)
    sf.write(tmp_path / "mic.wav", tone * 0.1, 16000)
    settings = Settings(output_dir=tmp_path / "out")
    statuses = []
    transcriber = TrackTranscriber()
    result = process_recording(tmp_path / "meeting.wav", settings, INFO.started_at, statuses.append, transcriber)
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "Peserta online:** Deploy ke staging hari ini ya" in md
    assert "Saya (mic):** Siap, saya cek flagging-nya" in md
    assert len(transcriber.calls) == 2
    assert any(s.startswith("Mentranskrip suaramu (mic)") for s in statuses)


def test_pipeline_uses_mix_when_meeting_track_is_silent(tmp_path, monkeypatch):
    """Rapat offline: jalur meeting hening, jadi cukup satu transkripsi tanpa label."""
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    tone = np.sin(np.arange(16000 * 2) / 5).astype("float32")
    sf.write(tmp_path / "meeting.wav", tone * 0.1, 16000)
    sf.write(tmp_path / "sistem.wav", np.zeros(32000, dtype="float32"), 16000)
    sf.write(tmp_path / "mic.wav", tone * 0.1, 16000)
    transcriber = TrackTranscriber()
    result = process_recording(tmp_path / "meeting.wav", Settings(output_dir=tmp_path / "out"),
                               INFO.started_at, lambda _: None, transcriber)
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "Siap, saya cek flagging-nya" in md
    assert "Saya (mic):" not in md


def test_condensed_removes_long_silence_and_maps_time_back():
    sr = 16000
    tone = (np.sin(np.arange(sr * 2) / 5) * 0.1).astype("float32")
    audio = np.zeros(sr * 30, dtype="float32")
    audio[sr * 1: sr * 3] = tone          # ucapan 1-3 s
    audio[sr * 20: sr * 22] = tone        # ucapan 20-22 s, setelah hening 17 detik
    noise = np.random.default_rng(0).normal(0, 0.0008, len(audio)).astype("float32")  # derau ruangan
    audio += noise
    spans = speech_spans(audio)
    assert len(spans) == 2
    condensed = Condensed(audio)
    assert 4.5 < condensed.seconds < 6  # 30 detik -> +-5 detik
    # Detik ke-0,3 audio ringkas = awal ucapan pertama; detik setelah jeda = awal ucapan kedua (20 s asli).
    assert condensed.original_time(0.3) == pytest.approx(1.0, abs=0.15)
    second_start = condensed.map[1][0]
    assert condensed.original_time(second_start + 0.3) == pytest.approx(20.0, abs=0.15)


def test_condensed_keeps_continuous_speech_and_drops_digital_silence():
    sr = 16000
    continuous = (np.sin(np.arange(sr * 10) / 5) * 0.1).astype("float32")
    assert Condensed(continuous).seconds == pytest.approx(10, abs=0.1)
    assert Condensed(np.zeros(sr * 10, dtype="float32")).seconds == 0


def test_resolve_model_auto_depends_on_mac(monkeypatch):
    import meeting_notes.transcriber as tr

    assert resolve_model("large-v3-turbo") == "large-v3-turbo"
    monkeypatch.setattr(tr, "is_apple_silicon", lambda: True)
    monkeypatch.setattr(tr, "physical_ram_gb", lambda: 16.0)
    assert resolve_model("auto") == "large-v3"
    monkeypatch.setattr(tr, "physical_ram_gb", lambda: 8.0)
    assert resolve_model("auto") == "large-v3-turbo"
    monkeypatch.setattr(tr, "is_apple_silicon", lambda: False)
    monkeypatch.setattr(tr, "physical_ram_gb", lambda: 64.0)
    assert resolve_model("auto") == "large-v3-turbo"


class ChunkTranscriber:
    """Mencatat potongan yang ditranskripsi; satu segmen per potongan pada detik awalnya."""

    vocabulary = ""
    model_size = "large-v3-turbo"

    def __init__(self):
        self.chunks = []
        self.contexts = []
        self.last_context = ""

    def transcribe_chunk(self, chunk, offset=0.0, context=""):
        self.chunks.append((offset, len(chunk) / 16000))
        self.contexts.append(context)
        self.last_context = f"akhir {offset:.0f}"
        return [Segment(offset, offset + 1, f"potongan di {offset:.0f}")]

    def transcribe(self, audio, on_progress=None, offset=0.0):
        segments = self.transcribe_chunk(audio, offset) if len(audio) else []
        if on_progress:
            on_progress(1.0)
        return segments

    def transcribe_wav(self, reader, start=0, on_progress=None):
        return self.transcribe(reader.read(start), on_progress, offset=start / 16000)


def _speech(seconds):
    return (np.sin(np.arange(int(16000 * seconds)) / 5) * 0.1).astype("float32")


def test_growing_wav_reads_file_still_being_written(tmp_path):
    from meeting_notes.wavio import GrowingWav

    path = tmp_path / "mic.wav"
    sf.write(path, _speech(3), 16000, subtype="PCM_16")
    with path.open("r+b") as f:  # header seperti saat aplikasi masih menulis: ukuran data belum diperbarui
        f.seek(4)
        f.write(b"\0\0\0\0")
        f.seek(40)
        f.write(b"\0\0\0\0")
    reader = GrowingWav(path)
    assert reader.samples() == 48000
    np.testing.assert_allclose(reader.read(16000, 16010), _speech(3)[16000:16010], atol=1e-4)


def test_background_transcription_then_process_only_transcribes_the_rest(tmp_path, monkeypatch):
    from meeting_notes import incremental

    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    minutes = 7
    for name in ("meeting.wav", "sistem.wav", "mic.wav"):
        sf.write(tmp_path / name, _speech(60 * minutes), 16000, subtype="PCM_16")

    background = ChunkTranscriber()
    state = incremental.load_state(tmp_path)
    for name, file in incremental.TRACKS.items():
        incremental.advance(tmp_path, state, background, name, incremental.GrowingWav(tmp_path / file))
    # Bicara tanpa jeda: dipotong paling lambat tiap 7 detik; potongan terakhir (rapat masih berjalan) ditunda.
    saved = incremental.load_state(tmp_path)
    assert 7 * 60 - 11 < saved["sistem"]["until"] < 7 * 60
    assert len(background.chunks) == 2 * len(saved["sistem"]["segments"])
    assert all(1.5 <= seconds <= 10.01 for _, seconds in background.chunks)
    # Setiap potongan menerima akhir kalimat potongan sebelumnya di jalur yang sama.
    assert background.contexts[1] == "akhir 0" and saved["sistem"]["context"].startswith("akhir")

    final = ChunkTranscriber()
    result = process_recording(tmp_path / "meeting.wav", Settings(output_dir=tmp_path / "out"),
                               INFO.started_at, lambda _: None, final)
    # Saat rapat selesai hanya sisa audio yang ditranskripsi, satu kali per jalur.
    assert [round(offset) for offset, _ in final.chunks] == [round(saved["sistem"]["until"])] * 2
    assert all(seconds < 11 for _, seconds in final.chunks)
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "potongan di 0" in md and f"potongan di {saved['sistem']['until']:.0f}" in md


def test_markdown_escapes_table_cells_and_lists_risks(tmp_path):
    summary = SUMMARY.model_copy(update={
        "action_items": [ActionItem(task="Cek flag A | B\ndi staging", owner="Budi", deadline="-")],
    })
    md = render_markdown(INFO, SEGMENTS, summary, corrections={("ef e | x", "FE"): 1})
    assert "| 1 | Cek flag A \\| B di staging | Budi | - |" in md
    assert "| ef e \\| x | FE | 1 |" in md
    assert "## Risiko & Blocker" in md and "Vendor bisa terlambat lagi" in md
    doc = Document(write_docx(tmp_path / "a.docx", INFO, SEGMENTS, summary))
    assert any(p.text == "Risiko & Blocker" for p in doc.paragraphs)


def _mac_recording(folder, seconds=3):
    for name in ("meeting.wav", "sistem.wav", "mic.wav"):
        sf.write(folder / name, _speech(seconds), 16000, subtype="PCM_16")


def _break_header(path):
    """Seperti rekaman yang tidak sempat ditutup rapi: ukuran di header WAV = 0."""
    with path.open("r+b") as f:
        f.seek(4)
        f.write(b"\0\0\0\0")
        f.seek(40)
        f.write(b"\0\0\0\0")


def test_unfinalized_recording_is_still_processed(tmp_path, monkeypatch):
    _no_api_key(monkeypatch)
    monkeypatch.setattr(summarizer_module, "find_claude_cli", lambda: None)
    _mac_recording(tmp_path, seconds=4)
    for name in ("meeting.wav", "sistem.wav", "mic.wav"):
        _break_header(tmp_path / name)
    final = ChunkTranscriber()
    result = process_recording(tmp_path / "meeting.wav", Settings(output_dir=tmp_path / "out"),
                               INFO.started_at, lambda _: None, final)
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "**Durasi:** 00:04" in md
    assert [round(seconds) for _, seconds in final.chunks] == [4, 4]


def test_retry_reuses_transcript_and_retries_claude_once(tmp_path, monkeypatch):
    from meeting_notes import pipeline

    monkeypatch.setattr(pipeline, "SUMMARY_RETRY_DELAY", 0)
    _mac_recording(tmp_path)
    calls = {"n": 0}

    class Flaky:
        def summarize(self, transcript, glossary=(), marks=()):
            calls["n"] += 1
            raise RuntimeError("usage limit reached")

    monkeypatch.setattr(pipeline, "make_summarizer", lambda settings: (Flaky(), None))
    settings = Settings(output_dir=tmp_path / "out")
    first = process_recording(tmp_path / "meeting.wav", settings, INFO.started_at, lambda _: None, ChunkTranscriber())
    assert calls["n"] == 2 and not first.summarized
    assert "usage limit reached" in first.note and "Susun ulang" in first.note
    assert (tmp_path / "transkrip_final.json").exists()

    class Works:
        def summarize(self, transcript, glossary=(), marks=()):
            assert "potongan di 0" in transcript
            return SUMMARY

    monkeypatch.setattr(pipeline, "make_summarizer", lambda settings: (Works(), None))
    untouched = ChunkTranscriber()
    second = process_recording(tmp_path / "meeting.wav", settings, INFO.started_at, lambda _: None, untouched)
    assert second.summarized and second.title == "Sinkronisasi Vendor"
    assert untouched.chunks == []  # tidak mentranskripsi ulang


def test_wav_reader_handles_extra_chunks_and_rejects_other_formats(tmp_path):
    import struct

    from meeting_notes.wavio import GrowingWav, is_pcm_wav

    samples = (np.arange(1600) % 100 - 50).astype("<i2")
    fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
    body = b"JUNK" + struct.pack("<I", 28) + b"\0" * 28 + b"fmt " + struct.pack("<I", 16) + fmt
    body += b"FLLR" + struct.pack("<I", 6) + b"\0" * 6 + b"data" + struct.pack("<I", 0) + samples.tobytes()
    path = tmp_path / "apple.wav"
    path.write_bytes(b"RIFF" + struct.pack("<I", 0) + b"WAVE" + body)
    assert is_pcm_wav(path)
    np.testing.assert_allclose(GrowingWav(path).read(), samples / 32768, atol=1e-6)
    stereo = tmp_path / "stereo.wav"
    sf.write(stereo, np.zeros((1600, 2), dtype="float32"), 44100)
    assert not is_pcm_wav(stereo)
    assert not is_pcm_wav(tmp_path / "tidak-ada.wav")


class PromptRecorder:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio, prompt):
        self.calls.append((len(audio) / 16000, prompt))
        n = len(self.calls)
        return [Segment(1.0, 2.0, f"kalimat ke {n} soal flagging")]


def test_every_whisper_window_gets_glossary_and_previous_context():
    transcriber = Transcriber(engine="faster-whisper")
    transcriber.engine = PromptRecorder()
    transcriber.vocabulary = "FE, flagging"
    # 70 detik ucapan dengan jeda pendek tiap 5 detik (tidak dipangkas karena < 1,5 detik).
    audio = np.concatenate([np.concatenate([_speech(4.5), np.zeros(8000, dtype="float32")]) for _ in range(14)])
    segments = transcriber.transcribe_chunk(audio, offset=100.0)
    calls = transcriber.engine.calls
    assert len(calls) == 3 and all(seconds <= 28.01 for seconds, _ in calls)
    assert all(prompt.startswith("Istilah: flagging, FE.") for _, prompt in calls)
    assert calls[1][1].endswith("kalimat ke 1 soal flagging")
    assert calls[2][1].endswith("kalimat ke 2 soal flagging")
    # Waktu tiap jendela dipetakan kembali ke rekaman asli (offset + posisi jendela).
    starts = [round(s.start) for s in segments]
    assert starts[0] == 101 and 120 < starts[1] < 135 and starts[2] > starts[1] + 20


def test_transcribe_wav_streams_chunks_and_matches_offsets(tmp_path):
    from meeting_notes.wavio import GrowingWav

    path = tmp_path / "mic.wav"
    sf.write(path, _speech(25), 16000, subtype="PCM_16")
    transcriber = Transcriber(engine="faster-whisper", chunk_seconds=10)
    recorder = PromptRecorder()
    transcriber.engine = recorder
    progress = []
    segments = transcriber.transcribe_wav(GrowingWav(path), start=16000 * 3, on_progress=progress.append)
    # 22 detik sisa -> 3 potongan (+-10 detik), tiap potongan dibaca terpisah dari file.
    assert len(recorder.calls) == 3
    assert segments[0].start == pytest.approx(4.0, abs=0.05)
    assert progress[-1] == 1.0


def test_live_update_waits_for_both_tracks_and_drops_echo():
    from meeting_notes.incremental import live_update

    state = {
        "sistem": {"until": 20.0, "segments": [[1, 4, "kita aktifkan feature flag di staging"],
                                               [12, 15, "nanti di-deploy setelah UAT"]]},
        "mic": {"until": 10.0, "segments": [[1.3, 4.2, "kita aktifkan feature flag di staging"],
                                            [6, 8, "oke siap"]]},
    }
    until, segments = live_update(state, 0.0)
    # Hanya sampai detik 10 (jalur mic baru sampai situ); gema di mic dibuang.
    assert until == 10.0
    assert [s.text for s in segments] == ["kita aktifkan feature flag di staging", "oke siap"]
    state["mic"]["until"] = 20.0
    until, segments = live_update(state, until)
    assert until == 20.0 and [s.text for s in segments] == ["nanti di-deploy setelah UAT"]
    assert live_update(state, until) == (20.0, [])


def test_follow_emits_live_lines(tmp_path):
    from meeting_notes import incremental

    for name in ("sistem.wav", "mic.wav"):
        sf.write(tmp_path / name, _speech(40), 16000, subtype="PCM_16")
    updates, rounds = [], iter(range(10))
    incremental.follow(tmp_path, ChunkTranscriber(), log=lambda _: None, poll_seconds=0,
                       should_stop=lambda: next(rounds, None) is None,
                       on_live=lambda until, segs: updates.append((until, [s.text for s in segs])))
    assert updates and updates[0][1] == ["potongan di 0"]
    assert all(a[0] < b[0] for a, b in itertools.pairwise(updates))


def _noise(seconds, level=0.004, seed=0):
    return (np.random.default_rng(seed).standard_normal(int(16000 * seconds)) * level).astype("float32")


def test_plan_cut_ends_utterance_at_pause():
    from meeting_notes.incremental import plan_cut

    window = np.concatenate([_speech(3), _noise(1.2)])
    cut, has_speech = plan_cut(window, floor=0.004, complete=False)
    # Dipotong di tengah jeda pertama setelah ucapan (bukan menunggu batas maksimum).
    assert has_speech and 3.0 < cut / 16000 < 3.4


def test_plan_cut_skips_noise_and_leading_silence():
    from meeting_notes.incremental import plan_cut

    cut, has_speech = plan_cut(_noise(10.4), floor=0.004, complete=True)
    assert not has_speech and cut / 16000 == pytest.approx(10.0, abs=0.06)
    cut, has_speech = plan_cut(np.concatenate([_noise(4), _speech(3)]), floor=0.004, complete=False)
    # Hening di depan dilewati dulu; ucapan dikerjakan pada giliran berikutnya dari awal ucapan.
    assert not has_speech and 3.7 < cut / 16000 < 4.0


def test_plan_cut_waits_for_unfinished_speech_then_caps_at_ten_seconds():
    from meeting_notes.incremental import plan_cut

    assert plan_cut(_speech(6), floor=0.004, complete=False) is None
    cut, has_speech = plan_cut(_speech(10.4), floor=0.004, complete=True)
    assert has_speech and 1.5 <= cut / 16000 <= 10.0


def test_plan_cut_short_reply_kept_whole():
    from meeting_notes.incremental import plan_cut

    cut, has_speech = plan_cut(np.concatenate([_speech(0.8), _noise(3)]), floor=0.004, complete=False)
    # "Oke siap" (0,8 detik) tetap ditranskripsi, digabung dengan jeda sesudahnya sampai 1,5 detik.
    assert has_speech and cut / 16000 == pytest.approx(1.5, abs=0.06)


def test_noise_floor_tracks_room_noise_not_speech():
    from meeting_notes.incremental import frame_levels, update_floor

    floor = update_floor(0.0, frame_levels(_noise(5)))
    assert 0.002 < floor < 0.005
    for _ in range(10):
        floor = update_floor(floor, frame_levels(_speech(10)))
    assert floor < 0.02


def test_plan_cut_never_skips_loud_speech_even_with_wrong_noise_floor():
    from meeting_notes.incremental import plan_cut

    # Perkiraan derau keliru setinggi suara (rekaman dimulai di tengah orang bicara).
    _, has_speech = plan_cut(_speech(10.4), floor=0.07, complete=True)
    assert has_speech


def test_live_correction_latency_simulation():
    """Regresi: koreksi Whisper tampil +-1-3 detik setelah ucapan selesai (sebelum 3.4.5: +-9 detik)."""
    import importlib.util
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("simulasi_live", root / "tools" / "simulasi_live.py")
    sim = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sim)
    module = sim.load(root / "meeting_notes" / "incremental.py", "meeting_notes._sim_test")
    tracks, utterances = sim.make_tracks(5)
    latency, total, _, left = sim.run(module, tracks, utterances, 5)
    assert len(latency) == total
    assert np.median(latency) < 3.0 and np.percentile(latency, 90) < 5.0
    assert left < 5


def test_plan_cut_skips_short_click_in_noise():
    from meeting_notes.incremental import plan_cut

    window = _noise(4)
    window[16000:16000 + 1600] += 0.2  # ketukan/klik 0,1 detik
    _, has_speech = plan_cut(window, floor=0.004, complete=False)
    assert not has_speech


def test_live_update_never_shows_repetition_hallucination():
    from meeting_notes.incremental import live_update

    state = {
        "sistem": {"until": 20.0, "segments": [[1, 9, "Pada " * 25], [10, 14, "nanti di-deploy setelah UAT"]]},
        "mic": {"until": 20.0, "segments": [[15, 17, "terima kasih telah menonton"]]},
    }
    _, segments = live_update(state, 0.0)
    assert [s.text for s in segments] == ["nanti di-deploy setelah UAT"]


def test_base_corrections_fix_apple_dev_term_mishearings():
    pairs = read_corrections(BASE_CORRECTIONS_PATH)
    text, _ = apply_corrections("Di sini macet jam 8 dari front N ada pada dari tadi, back end aman", pairs)
    assert text == "Di sini macet jam 8 dari frontend ada pada dari tadi, backend aman"
    text, _ = apply_corrections("tolong cek full request di setaging", pairs)
    assert text == "tolong cek pull request di staging"
    # Kata biasa yang mirip tidak ikut berubah.
    assert apply_corrections("di depan (front) nanti", pairs)[0] == "di depan (front) nanti"
