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


# ── commit sequence (holdback policy, append-only) ────────────────────────────

def test_commit_sequence_holds_back_unstable_tail(monkeypatch):
    monkeypatch.setattr(main, "HOLDBACK_WORDS", 2)
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    t = main.IncrementalTranscriber(FakeSession())

    # each pass commits all but the trailing 2 words; first pass already types
    t._commit_step(["a", "b", "c", "d"], final=False)          # commit a b
    t._commit_step(["a", "b", "c", "d", "e"], final=False)     # commit c
    t._commit_step(["a", "b", "c", "d", "e", "f"], final=False)  # commit d
    t._commit_step(["a", "b", "c", "d", "e", "f"], final=True)   # final suffix e f

    assert typed == ["a b", " c", " d", " e f"]
    assert " ".join(typed).split() == ["a", "b", "c", "d", "e", "f"]  # no dup
    assert t._committed == ["a", "b", "c", "d", "e", "f"]


def test_short_clip_commits_nothing_until_final(monkeypatch):
    monkeypatch.setattr(main, "HOLDBACK_WORDS", 2)
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    t = main.IncrementalTranscriber(FakeSession())
    t._commit_step(["hi", "there"], final=False)  # all words within holdback → nothing
    assert typed == []
    t._commit_step(["hi", "there"], final=True)
    assert typed == ["hi there"]


def test_final_divergence_is_logged_not_erased(monkeypatch, caplog):
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    t = main.IncrementalTranscriber(FakeSession())
    t._committed = ["the", "quikc"]      # already typed (with a typo)

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
    monkeypatch.setattr(main, "HOLDBACK_WORDS", 2)
    monkeypatch.setattr(main, "_frames_to_wav", lambda frames: b"")
    typed = []
    monkeypatch.setattr(main, "_type_text", lambda chunk: typed.append(chunk))

    session = FakeSession(frames=["frame"])
    t = main.IncrementalTranscriber(session)

    # Partial passes commit all but the last 2 words ("hello world"); the final
    # pass (after _stop is set) commits the held-back tail plus "you".
    monkeypatch.setattr(
        main, "_transcribe",
        lambda wav: "hello world how are you" if t._stop.is_set() else "hello world how are",
    )

    t.start()
    time.sleep(0.25)                     # let several partial passes run
    final_text = t.finish_and_flush(["frame"])

    assert t._worker.is_alive() is False
    assert final_text == "hello world how are you"
    assert " ".join(typed).split() == ["hello", "world", "how", "are", "you"]  # no duplicates
