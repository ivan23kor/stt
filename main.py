#!/usr/bin/env python3
import io
import json
import logging
import os
import subprocess
import tempfile
import threading
import time
import wave

import httpx
import numpy as np
import sounddevice as sd
from pynput import keyboard

GROQ_API_KEY = os.environ["GROQ_API_KEY"]
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_CHAT_URL = "https://api.groq.com/openai/v1/chat/completions"
SAMPLE_RATE = 16000
CHANNELS = 1
TRANSCRIPTION_PROMPT = os.environ.get(
    "STT_TRANSCRIPTION_PROMPT",
    "Dictation for general desktop text entry.",
)
SUMMARY_MODEL = os.environ.get("STT_SUMMARY_MODEL", "openai/gpt-oss-20b")
SUMMARY_PROMPT = os.environ.get(
    "STT_SUMMARY_PROMPT",
    "You summarize text to be read aloud. Reply with a short spoken-friendly gist "
    "(2-4 sentences), plain prose only — no markdown, lists, or headings.",
)
PROGRESS_ENABLED = os.environ.get("STT_PROGRESS", "1") != "0"
PROGRESS_TICK_S  = 0.2   # redraw cadence (seconds)
PROGRESS_CAP     = 0.95  # never claim 100% until the result actually arrives
ETA_OPTIMISM     = 0.8   # bias estimate low so dots fill early and wait at full
ETA_BASE         = float(os.environ.get("STT_ETA_BASE", "0.6"))    # network/queue floor (s)
ETA_PER_SEC      = float(os.environ.get("STT_ETA_PER_SEC", "0.3")) # decode seconds per audio second
CAL_PATH         = os.path.expanduser("~/.cache/stt/latency-cal.json")

PIPER_BIN = os.path.expanduser("~/.local/bin/piper")
PIPER_MODEL = os.environ.get(
    "STT_PIPER_MODEL",
    os.path.expanduser("~/.local/share/piper/en_US-amy-medium.onnx"),
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


class RecordingSession:
    def __init__(self):
        self._frames = []
        self._frames_lock = threading.Lock()
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=1024,
            callback=self._audio_callback,
        )

    def _audio_callback(self, indata, _frame_count, _time_info, _status):
        with self._frames_lock:
            self._frames.append(indata.copy())

    def start(self):
        self._stream.start()

    def stop_and_capture(self):
        self._stream.stop()
        self._stream.close()
        with self._frames_lock:
            return list(self._frames)


def _frames_to_wav(frames):
    pcm = np.concatenate(frames, axis=0)
    data = (pcm * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(data.tobytes())
    buf.seek(0)
    return buf.read()


def _transcribe(wav_bytes):
    with httpx.Client(
        timeout=httpx.Timeout(connect=10.0, write=120.0, read=60.0, pool=5.0)
    ) as client:
        resp = client.post(
            GROQ_URL,
            headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
            files={"file": ("audio.wav", wav_bytes, "audio/wav")},
            data={
                "model": "whisper-large-v3-turbo",
                "language": "en",
                "response_format": "text",
                "prompt": TRANSCRIPTION_PROMPT,
            },
        )
        resp.raise_for_status()
        return resp.text.strip()


def _type_text(text):
    if text:
        subprocess.run(
            ["xdotool", "type", "--clearmodifiers", "--delay", "0", text],
            check=True,
        )


# ── TTS / speak-selection ─────────────────────────────────────────────────────

def _get_selection():
    """Return the current X primary selection, falling back to clipboard."""
    for sel in ("primary", "clipboard"):
        result = subprocess.run(
            ["xclip", "-o", "-selection", sel],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return ""


def _summarize(text):
    """Send text to Groq and return a short spoken-friendly gist."""
    with httpx.Client(
        timeout=httpx.Timeout(connect=10.0, write=120.0, read=60.0, pool=5.0)
    ) as client:
        resp = client.post(
            GROQ_CHAT_URL,
            headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
            json={
                "model": SUMMARY_MODEL,
                "temperature": 0.2,
                "messages": [
                    {"role": "system", "content": SUMMARY_PROMPT},
                    {"role": "user", "content": text},
                ],
            },
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"].strip()


def _speak(text):
    """Synthesize text with local Piper TTS and play via mpv."""
    # Kill any in-progress TTS playback first.
    subprocess.run(["pkill", "-f", "mpv.*tts-audio"], capture_output=True)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False, prefix="tts-") as f:
        tmp_path = f.name

    try:
        piper = subprocess.Popen(
            [PIPER_BIN, "--model", PIPER_MODEL, "--output_raw"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        ffmpeg = subprocess.Popen(
            [
                "ffmpeg", "-f", "s16le", "-ar", "22050", "-ac", "1",
                "-i", "-", "-y", tmp_path,
            ],
            stdin=piper.stdout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        piper.stdin.write(text.encode())
        piper.stdin.close()
        piper.wait()
        ffmpeg.wait()

        proc = subprocess.Popen(
            ["mpv", "--no-video", "--no-osd-bar", "--title=tts-audio", tmp_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        proc.wait()
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _stop_speech():
    subprocess.run(["pkill", "-f", "mpv.*tts-audio"], capture_output=True)


def _toggle_pause():
    result = subprocess.run(
        ["playerctl", "--list-all"], capture_output=True, text=True
    )
    instance = next(
        (line for line in result.stdout.splitlines() if "mpv" in line), None
    )
    if instance:
        subprocess.run(
            ["playerctl", f"--player={instance}", "play-pause"], check=False
        )
    else:
        log.info("No TTS playback running")


def _speak_selection():
    """Grab selection, summarize with Groq, speak with Piper."""
    text = _get_selection()
    if not text:
        subprocess.run(
            ["notify-send", "-u", "normal", "-i", "audio-volume-high",
             "Speak", "No text selected"],
            check=False,
        )
        return
    log.info("Summarizing %d chars...", len(text))
    try:
        gist = _summarize(text)
        log.info("→ gist: %r", gist)
        _speak(gist)
    except Exception as exc:
        log.error("Speak-selection failed: %s", exc)
        subprocess.run(
            ["notify-send", "-u", "critical", "-i", "dialog-error",
             "Speak failed", str(exc)],
            check=False,
        )


def _render_dots(frac):
    """Return 1–5 dots, one per 20% (1 dot at 0%, 5 dots at >=80%).

    Kept tiny on purpose: each in-place update erases len(shown) chars via
    synthetic BackSpace keystrokes, so 1–5 chars stays cheap and won't
    saturate X input.
    """
    return "." * min(5, 1 + int(max(0.0, min(1.0, frac)) / 0.2))


def _load_cal():
    """Return the persisted ETA-calibration multiplier (default 1.0)."""
    try:
        with open(CAL_PATH) as f:
            return float(json.load(f)["cal"])
    except Exception:
        return 1.0


def _estimate_eta(duration_s):
    """Estimate transcription latency from audio duration (seconds)."""
    return max(0.3, ETA_OPTIMISM * (ETA_BASE + ETA_PER_SEC * duration_s) * _load_cal())


def _update_calibration(duration_s, latency):
    """Nudge the ETA multiplier toward reality via a clamped EMA."""
    base = ETA_BASE + ETA_PER_SEC * duration_s
    if base <= 0:
        return
    cal = max(0.3, min(3.0, 0.8 * _load_cal() + 0.2 * (latency / base)))
    try:
        os.makedirs(os.path.dirname(CAL_PATH), exist_ok=True)
        with open(CAL_PATH, "w") as f:
            json.dump({"cal": cal}, f)
    except OSError:
        pass


class CaretProgress:
    """Types a live percentage at the cursor while waiting for transcription.

    All xdotool calls are serialized under a lock so ticks and finish()
    can never interleave. finish() erases the percentage and leaves a clean
    caret so that _type_text() can insert the real text immediately after.
    """

    def __init__(self, eta):
        self._eta = eta
        self._start = None
        self._shown = ""      # currently rendered bar text (or "" if none yet)
        self._done = False
        self._lock = threading.Lock()
        self._timer = None

    def start(self):
        self._start = time.monotonic()
        self._timer = threading.Timer(PROGRESS_TICK_S, self._tick)
        self._timer.daemon = True
        self._timer.start()

    def _draw(self, new):
        """Erase the current text and type the new one (noop if unchanged)."""
        if new == self._shown:
            return
        if self._shown:
            n = len(self._shown)
            subprocess.run(
                ["xdotool", "key", "--clearmodifiers",
                 "--repeat", str(n), "BackSpace"],
                check=False,
            )
        if new:
            subprocess.run(
                ["xdotool", "type", "--clearmodifiers", "--delay", "0", new],
                check=False,
            )
        self._shown = new

    def _tick(self):
        with self._lock:
            if self._done:
                return
            elapsed = time.monotonic() - self._start
            frac = min(PROGRESS_CAP, elapsed / self._eta)
            self._draw(_render_dots(frac))
            self._timer = threading.Timer(PROGRESS_TICK_S, self._tick)
            self._timer.daemon = True
            self._timer.start()

    def finish(self):
        """Erase the percentage completely, leaving the caret clean."""
        with self._lock:
            self._done = True
            if self._timer:
                self._timer.cancel()
                self._timer = None
            self._draw("")


def _on_release(session):
    captured = session.stop_and_capture()
    duration_s = len(captured) * 1024 / SAMPLE_RATE  # approx
    if duration_s < 0.3:
        log.info("Too short (%.1fs), ignored", duration_s)
        return
    log.info("Transcribing %.1fs of audio...", duration_s)
    bar = CaretProgress(_estimate_eta(duration_s)) if PROGRESS_ENABLED else None
    if bar:
        bar.start()
    t0 = time.monotonic()
    try:
        wav = _frames_to_wav(captured)
        text = _transcribe(wav)
        latency = time.monotonic() - t0
        if bar:
            bar.finish()  # erase bar before typing result
        log.info("→ %r (%.1fs)", text, latency)
        _type_text(text)
        _update_calibration(duration_s, latency)
    except Exception as exc:
        if bar:
            bar.finish()  # erase bar before showing failure notification
        log.error("Transcription failed: %s", exc)
        subprocess.run(
            [
                "notify-send",
                "-u", "critical",
                "-i", "microphone-sensitivity-muted-symbolic",
                "STT failed",
                f"{duration_s:.0f}s clip — {type(exc).__name__}: {exc}",
            ],
            check=False,
        )


def main():
    log.info("STT daemon ready — hold Ctrl+Space to dictate, Ctrl+Alt+S to speak selection")

    ctrl_held = False
    space_held = False
    current_session = [None]
    session_lock = threading.Lock()
    stop_timer = [None]

    def _schedule_stop():
        if stop_timer[0]:
            stop_timer[0].cancel()
        with session_lock:
            session = current_session[0]
        if session is None:
            return

        def _do_stop():
            with session_lock:
                if current_session[0] is not session:
                    return
                current_session[0] = None
            threading.Thread(target=_on_release, args=(session,), daemon=True).start()
        t = threading.Timer(0.08, _do_stop)
        t.daemon = True
        t.start()
        stop_timer[0] = t

    def _cancel_stop():
        if stop_timer[0]:
            stop_timer[0].cancel()
            stop_timer[0] = None

    def on_press(key):
        nonlocal ctrl_held, space_held
        if key in (keyboard.Key.ctrl_l, keyboard.Key.ctrl_r):
            ctrl_held = True
        elif key == keyboard.Key.space:
            space_held = True
        if ctrl_held and space_held:
            _cancel_stop()
            with session_lock:
                if current_session[0] is not None:
                    return
                session = RecordingSession()
                current_session[0] = session
            try:
                session.start()
            except Exception:
                with session_lock:
                    if current_session[0] is session:
                        current_session[0] = None
                session.stop_and_capture()
                raise
            log.info("Recording...")

    def on_release(key):
        nonlocal ctrl_held, space_held
        if key in (keyboard.Key.ctrl_l, keyboard.Key.ctrl_r):
            ctrl_held = False
        elif key == keyboard.Key.space:
            space_held = False
        if not (ctrl_held and space_held):
            _schedule_stop()

    hotkeys = keyboard.GlobalHotKeys({
        "<ctrl>+<alt>+s": lambda: threading.Thread(
            target=_speak_selection, daemon=True
        ).start(),
        "<ctrl>+<alt>+x": lambda: threading.Thread(
            target=_stop_speech, daemon=True
        ).start(),
        "<ctrl>+<alt>+p": lambda: threading.Thread(
            target=_toggle_pause, daemon=True
        ).start(),
    })
    hotkeys.start()

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


if __name__ == "__main__":
    main()
