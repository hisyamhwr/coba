from types import SimpleNamespace

import numpy as np
import pytest
import requests
import soundfile as sf

from meeting_notes import cloud_stt, compare
from meeting_notes.cloud_stt import AssemblyAI, Deepgram, ElevenLabs, transcribe_with_fallback
from meeting_notes.config import Settings
from meeting_notes.transcriber import Segment, to_paragraphs


def _resp(payload, status=200):
    def raise_for_status():
        if status >= 400:
            raise requests.HTTPError(response=SimpleNamespace(status_code=status))

    return SimpleNamespace(json=lambda: payload, raise_for_status=raise_for_status, status_code=status)


@pytest.fixture
def wav(tmp_path):
    path = tmp_path / "a.wav"
    sf.write(path, np.zeros(1600, dtype="float32"), 16000)
    return path


def test_elevenlabs_request_and_parsing(monkeypatch, wav):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    calls = {}

    def fake_post(url, headers, data, files, timeout):
        calls.update(url=url, headers=headers, data=data)
        return _resp({"words": [
            {"text": "setor", "start": 0.0, "end": 0.4, "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "start": 0.4, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "tunai", "start": 0.5, "end": 0.9, "type": "word", "speaker_id": "speaker_0"},
            {"text": "oke", "start": 1.2, "end": 1.5, "type": "word", "speaker_id": "speaker_1"},
        ]})

    monkeypatch.setattr(cloud_stt.requests, "post", fake_post)
    segments = ElevenLabs().transcribe(wav, ["setor tunai", "x" * 60, "satu dua tiga empat lima enam"])
    assert calls["url"] == "https://api.elevenlabs.io/v1/speech-to-text"
    assert calls["headers"] == {"xi-api-key": "k"}
    assert ("model_id", "scribe_v2") in calls["data"]
    # Istilah terlalu panjang (>50 karakter atau >5 kata) tidak dikirim.
    assert [v for k, v in calls["data"] if k == "keyterms"] == ["setor tunai"]
    assert segments == [Segment(0.0, 0.9, "setor tunai", "speaker_0"), Segment(1.2, 1.5, "oke", "speaker_1")]


def test_assemblyai_upload_submit_poll(monkeypatch, wav):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "k")
    monkeypatch.setattr(cloud_stt.time, "sleep", lambda s: None)
    posts = []

    def fake_post(url, headers, timeout, data=None, json=None):
        posts.append((url, json))
        if url.endswith("/upload"):
            return _resp({"upload_url": "https://cdn/x"})
        return _resp({"id": "t1"})

    polls = iter([{"status": "processing"}, {"status": "completed", "utterances": [
        {"start": 0, "end": 1500, "text": "Nasabah setor tunai.", "speaker": "A"}]}])
    monkeypatch.setattr(cloud_stt.requests, "post", fake_post)
    monkeypatch.setattr(cloud_stt.requests, "get", lambda url, headers, timeout: _resp(next(polls)))
    segments = AssemblyAI().transcribe(wav, ["setor tunai"])
    body = posts[1][1]
    assert body["audio_url"] == "https://cdn/x"
    assert body["speech_models"][0] == "universal-3-5-pro"
    assert body["language_detection_options"] == {"expected_languages": ["id", "en"], "code_switching": True}
    assert body["keyterms_prompt"] == ["setor tunai"]
    assert segments == [Segment(0, 1.5, "Nasabah setor tunai.", "speaker_A")]


def test_assemblyai_error_status(monkeypatch, wav):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "k")
    monkeypatch.setattr(cloud_stt.requests, "post", lambda url, **kw: _resp({"upload_url": "u", "id": "t"}))
    monkeypatch.setattr(cloud_stt.requests, "get", lambda url, **kw: _resp({"status": "error", "error": "bad audio"}))
    with pytest.raises(RuntimeError, match="bad audio"):
        AssemblyAI().transcribe(wav, [])


def test_deepgram_request_and_parsing(monkeypatch, wav):
    monkeypatch.setenv("DEEPGRAM_API_KEY", "k")
    calls = {}

    def fake_post(url, params, data, timeout, headers):
        calls.update(params=params, headers=headers)
        utterance = {"start": 0.5, "end": 2.0, "transcript": "Tarik tunai.", "speaker": 1}
        return _resp({"results": {"utterances": [utterance]}})

    monkeypatch.setattr(cloud_stt.requests, "post", fake_post)
    segments = Deepgram().transcribe(wav, ["teller"])
    assert ("model", "nova-3") in calls["params"] and ("language", "id") in calls["params"]
    assert ("keyterm", "teller") in calls["params"]
    assert calls["headers"]["Authorization"] == "Token k"
    assert segments == [Segment(0.5, 2.0, "Tarik tunai.", "speaker_1")]


def test_fallback_retries_without_keyterms_on_400():
    seen = []

    class Picky:
        def transcribe(self, path, keyterms):
            seen.append(list(keyterms))
            if keyterms:
                raise requests.HTTPError(response=SimpleNamespace(status_code=400))
            return [Segment(0, 1, "ok")]

    assert transcribe_with_fallback(Picky(), None, ["a"]) == [Segment(0, 1, "ok")]
    assert seen == [["a"], []]


def test_paragraphs_do_not_merge_different_speakers():
    segs = [
        Segment(0, 1, "Halo", "speaker_0"), Segment(1.2, 2, "Hai", "speaker_1"), Segment(2.1, 3, "juga", "speaker_1"),
    ]
    assert to_paragraphs(segs) == [Segment(0, 1, "Halo", "speaker_0"), Segment(1.2, 3, "Hai juga", "speaker_1")]


def test_compare_report(monkeypatch, tmp_path):
    for key in ("ELEVENLABS_API_KEY", "ASSEMBLYAI_API_KEY", "DEEPGRAM_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    monkeypatch.setenv("DEEPGRAM_API_KEY", "k")
    monkeypatch.setattr(ElevenLabs, "transcribe", lambda self, p, k: [Segment(1, 2, "setor tunai <b>", "speaker_0")])

    def broken(self, p, k):
        raise RuntimeError("401 Unauthorized")

    monkeypatch.setattr(Deepgram, "transcribe", broken)
    audio = tmp_path / "rapat.wav"
    sf.write(audio, np.zeros(16000 * 20, dtype="float32"), 16000)
    report = compare.compare(audio, Settings(output_dir=tmp_path / "out"), start=10, duration=5, include_local=False)
    page = report.read_text(encoding="utf-8")
    assert (report.parent / "potongan.wav").exists()
    assert sf.info(str(report.parent / "potongan.wav")).duration == 5
    assert "[00:11]" in page and "setor tunai &lt;b&gt;" in page
    assert "Gagal: 401 Unauthorized" in page
    assert "AssemblyAI" not in page  # tanpa API key dilewati


def _fake_recording(tmp_path):
    path = tmp_path / "rapat.wav"
    sf.write(path, np.zeros(16000 * 3, dtype="float32"), 16000)
    return path


class _NoLocal:
    vocabulary = ""

    def transcribe(self, audio, on_progress=None):
        return [Segment(0, 1, "dari whisper lokal")]


def test_pipeline_uses_cloud_engine_with_speakers(monkeypatch, tmp_path):
    from meeting_notes import pipeline

    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    seen = {}

    def fake(self, path, keyterms):
        seen.update(suffix=path.suffix, keyterms=keyterms)
        return [Segment(0, 2, "Halo semua.", "speaker_7"), Segment(2.5, 4, "Siap.", "speaker_3")]

    monkeypatch.setattr(ElevenLabs, "transcribe", fake)
    settings = Settings(output_dir=tmp_path / "out", transcription_engine="elevenlabs", summarizer="none")
    settings.output_dir.mkdir()
    settings.glossary_path.write_text("setor tunai\n", encoding="utf-8")
    result = pipeline.process_recording(_fake_recording(tmp_path), settings, on_status=lambda m: None,
                                        transcriber=_NoLocal())
    md = result.markdown_path.read_text(encoding="utf-8")
    assert seen["suffix"] == ".flac"
    # Kamus yang dipelajari lebih dulu, lalu kamus dasar (tanpa duplikat).
    assert seen["keyterms"][0] == "setor tunai" and "teller" in seen["keyterms"]
    assert seen["keyterms"].count("setor tunai") == 1
    assert "**[00:00] Pembicara 1:** Halo semua." in md
    assert "**[00:02] Pembicara 2:** Siap." in md
    assert "whisper lokal" not in md


def test_pipeline_falls_back_to_local_when_cloud_fails(monkeypatch, tmp_path):
    from meeting_notes import pipeline

    monkeypatch.setenv("DEEPGRAM_API_KEY", "k")

    def broken(self, path, keyterms):
        raise requests.ConnectionError("no internet")

    monkeypatch.setattr(Deepgram, "transcribe", broken)
    settings = Settings(output_dir=tmp_path / "out", transcription_engine="deepgram", summarizer="none")
    result = pipeline.process_recording(_fake_recording(tmp_path), settings, on_status=lambda m: None,
                                        transcriber=_NoLocal())
    md = result.markdown_path.read_text(encoding="utf-8")
    assert "dari whisper lokal" in md
    assert "Deepgram Nova-3 gagal (no internet), memakai Whisper lokal." in result.note


def test_pipeline_without_cloud_key_uses_local(monkeypatch, tmp_path):
    from meeting_notes import pipeline

    monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
    settings = Settings(output_dir=tmp_path / "out", transcription_engine="assemblyai", summarizer="none")
    result = pipeline.process_recording(_fake_recording(tmp_path), settings, on_status=lambda m: None,
                                        transcriber=_NoLocal())
    assert "ASSEMBLYAI_API_KEY belum diisi" in result.note
