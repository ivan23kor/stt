# STT

Linux desktop daemon for voice dictation and text-to-speech.

| Shortcut | Action |
|---|---|
| Hold `Ctrl+Space` | Record speech → transcribe → type into focused window |
| `Ctrl+Alt+S` | Summarize selected text with Groq → speak gist aloud (Piper, local) |
| `Ctrl+Alt+X` | Stop TTS playback |
| `Ctrl+Alt+P` | Pause / resume TTS playback |

Speech-to-text uses **Groq Whisper** (cloud, free tier).  
Text-to-speech uses **Piper** (local, free, offline).  
The summary step uses **Groq chat** (cloud, free tier, `openai/gpt-oss-20b`).

## Requirements

- Python 3.13
- `uv`
- `xdotool`, `xclip` — keyboard injection and X selection
- `piper` + a voice model (default `~/.local/share/piper/en_US-amy-medium.onnx`)
- `mpv`, `ffmpeg` — audio playback
- `playerctl` — pause/resume control
- A desktop session with keyboard and audio access
- `GROQ_API_KEY` in the process environment

## Run

```bash
uv sync
GROQ_API_KEY=... uv run python main.py
```

### Optional environment variables

```bash
export STT_TRANSCRIPTION_PROMPT="Dictation for general desktop text entry."
export STT_SUMMARY_MODEL="openai/gpt-oss-20b"   # Groq chat model for summarisation
export STT_SUMMARY_PROMPT="..."                  # Override the summarisation system prompt
export STT_PIPER_MODEL="$HOME/.local/share/piper/en_US-amy-medium.onnx"
```

The microphone is opened only while `Ctrl+Space` is held, then closed before
transcription starts.

## Autostart

Copy `stt-daemon.desktop` to `~/.config/autostart/stt-daemon.desktop` and make
sure `GROQ_API_KEY` is available in the desktop session environment.

## Commit Safety

This repo includes local Git hooks that run syntax, secret, Semgrep, and
dependency checks before commit and push:

```bash
git config core.hooksPath .githooks
```

Run the same checks manually:

```bash
scripts/security-check.sh
```
