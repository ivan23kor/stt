# STT

Linux desktop daemon for voice dictation and text-to-speech.

| Shortcut | Action |
|---|---|
| Hold `Ctrl+Space` | Record speech → transcribe → type into focused window |
| `Ctrl+Alt+S` | Read selected text verbatim (Piper, local) |
| `Ctrl+Alt+X` | Stop TTS playback |
| `Ctrl+Alt+P` | Pause / resume TTS playback |

Speech-to-text uses **Groq Whisper** (cloud, free tier).  
Text-to-speech uses **Piper** (local, free, offline).  
Piper speaks at `1.2×` speed by default.

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
export STT_PIPER_MODEL="$HOME/.local/share/piper/en_US-amy-medium.onnx"
export STT_PIPER_LENGTH_SCALE="0.833333"         # 1 / speed; default is 20% faster
```

The microphone is opened only while `Ctrl+Space` is held, then closed before
transcription starts.

### WSLg / Windows global shortcut

WSLg's X11 compatibility layer cannot see physical keyboard shortcuts from
Windows Chrome or Windows Terminal. Install the Windows-side bridge once:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Install-STT-Hotkey-Bridge.ps1
```

The bridge registers `Ctrl+Alt+S`, `Ctrl+Alt+P`, and `Ctrl+Alt+X` with Windows,
sends `Ctrl+C` to the focused application for speech requests, and streams the
copied selection to `scripts/speak-stdin.sh` in WSL. Pause/resume and stop are
handled by `scripts/control-playback.sh`. The bridge starts automatically from
the current Windows user's Startup folder; its diagnostic log is
`%LOCALAPPDATA%\IvanKorostelev\STT\hotkey-bridge.log`.
While it works, a non-focus-stealing overlay in the lower-right corner shows
copying, measured audio-preparation time, a determinate playback progress bar,
the remaining speech time, completion, and errors.

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
