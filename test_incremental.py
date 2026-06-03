"""Unit tests for the incremental (live) transcription algorithm.

Pure logic only — no audio capture, no xdotool, no network. `_type_text` and
`_transcribe` are monkeypatched so we exercise the commit/threading logic in
isolation.
"""
import logging
import os
import threading
import time

import pytest

os.environ.setdefault("GROQ_API_KEY", "test-key")  # main reads this at import

import main


class FakeSession:
    """Minimal stand-in for RecordingSession (just the bits the worker touches)."""

    def __init__(self, frames=None):
        self._frames = list(frames or [])
        self._frames_lock = threading.Lock()


# ── pure helpers ──────────────────────────────────────────────────────────────

@pytest.mark.parametrize("text,expected", [
    ("", []),
    ("hello", ["hello"]),
    ("  the   quick  brown ", ["the", "quick", "brown"]),
])
def test_tokenize(text, expected):
    assert main._tokenize(text) == expected


@pytest.mark.parametrize("a,b,n", [
    ([], [], 0),
    ([], ["a"], 0),
    (["a", "b", "c"], ["a", "b", "c"], 3),
    (["a", "b", "c"], ["a", "b", "x"], 2),
    (["a", "b"], ["a", "b", "c"], 2),
    (["x"], ["a"], 0),
])
def test_common_prefix_len(a, b, n):
    assert main._common_prefix_len(a, b) == n


# ── commit sequence (LocalAgreement-2, append-only) ───────────────────────────

def test_commit_sequence_appends_only_stable_words(monkeypatch):
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    t = main.IncrementalTranscriber(FakeSession())

    t._commit_step(["the", "quick", "brow"], final=False)   # tail unstable → nothing
    assert typed == []

    t._commit_step(["the", "quick", "brown"], final=False)  # "the quick" agreed
    t._commit_step(["the", "quick", "brown", "fox"], final=False)  # "brown" agreed
    t._commit_step(["the", "quick", "brown", "fox", "jumps"], final=True)  # final suffix

    assert typed == ["the quick", " brown", " fox jumps"]
    # no word typed twice, full text intact
    assert " ".join(typed).split() == ["the", "quick", "brown", "fox", "jumps"]
    assert t._committed == ["the", "quick", "brown", "fox", "jumps"]


def test_final_divergence_is_logged_not_erased(monkeypatch, caplog):
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    t = main.IncrementalTranscriber(FakeSession())
    t._committed = ["the", "quikc"]      # already typed (with a typo)
    t._prev_words = ["the", "quikc"]

    with caplog.at_level(logging.WARNING):
        t._commit_step(["the", "quick", "fox"], final=True)

    assert any("divergence at word 1" in r.message for r in caplog.records)
    assert typed == [" fox"]             # suffix appended, nothing erased
    assert t._committed == ["the", "quikc", "fox"]


# ── frame snapshot isolation ──────────────────────────────────────────────────

def test_snapshot_frames_is_independent_copy():
    session = FakeSession(frames=["a", "b"])
    t = main.IncrementalTranscriber(session)
    snap = t._snapshot_frames()
    session._frames.append("c")          # mutate after snapshot
    assert snap == ["a", "b"]


# ── threading smoke test ──────────────────────────────────────────────────────

def test_worker_runs_and_stops_cleanly(monkeypatch):
    monkeypatch.setattr(main, "PARTIAL_INTERVAL_S", 0.05)
    monkeypatch.setattr(main, "PARTIAL_MIN_AUDIO_S", 0.0)
    monkeypatch.setattr(main, "_frames_to_wav", lambda frames: b"")
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    session = FakeSession(frames=["frame"])
    t = main.IncrementalTranscriber(session)

    # Partial passes see "hello world"; the final pass (after _stop is set) adds "there".
    monkeypatch.setattr(
        main, "_transcribe",
        lambda wav: "hello world there" if t._stop.is_set() else "hello world",
    )

    t.start()
    time.sleep(0.25)                     # let several partial passes run
    final_text = t.finish_and_flush(["frame"])

    assert t._worker.is_alive() is False
    assert final_text == "hello world there"
    assert " ".join(typed).split() == ["hello", "world", "there"]  # no duplicates
