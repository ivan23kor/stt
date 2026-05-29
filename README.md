# STT

Small Linux desktop dictation daemon. Hold `Ctrl+Space` to record speech, release
to transcribe with Groq Whisper, and type the result into the focused window.

## Requirements

- Python 3.13
- `uv`
- `xdotool`
- A desktop session with keyboard and audio access
- `GROQ_API_KEY` in the process environment

## Run

```bash
uv sync
GROQ_API_KEY=... uv run python main.py
```

Optional:

```bash
export STT_TRANSCRIPTION_PROMPT="Dictation for general desktop text entry."
```

The microphone is opened only while `Ctrl+Space` is held, then closed before
transcription starts.

## Autostart

Copy `stt-daemon.desktop` to `~/.config/autostart/stt-daemon.desktop` and make
sure `GROQ_API_KEY` is available in the desktop session environment.
