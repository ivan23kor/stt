#!/usr/bin/env python3
import io
import logging
import os
import subprocess
import threading
import wave

import httpx
import numpy as np
import sounddevice as sd
from pynput import keyboard

GROQ_API_KEY = os.environ["GROQ_API_KEY"]
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
SAMPLE_RATE = 16000
CHANNELS = 1
TRANSCRIPTION_PROMPT = os.environ.get(
    "STT_TRANSCRIPTION_PROMPT",
    "Dictation for general desktop text entry.",
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
    with httpx.Client(timeout=httpx.Timeout(5.0, read=30.0)) as client:
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


def _on_release(session):
    captured = session.stop_and_capture()
    duration_s = len(captured) * 1024 / SAMPLE_RATE  # approx
    if duration_s < 0.3:
        log.info("Too short (%.1fs), ignored", duration_s)
        return
    log.info("Transcribing %.1fs of audio...", duration_s)
    try:
        wav = _frames_to_wav(captured)
        text = _transcribe(wav)
        log.info("→ %r", text)
        _type_text(text)
    except Exception as exc:
        log.error("Transcription failed: %s", exc)
        subprocess.run(
            [
                "notify-send",
                "-u", "critical",
                "-i", "microphone-sensitivity-muted-symbolic",
                "STT failed",
                str(exc),
            ],
            check=False,
        )


def main():
    log.info("STT daemon ready — hold Ctrl+Space to dictate")

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

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


if __name__ == "__main__":
    main()
