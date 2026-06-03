# STT daemon

## Restart after every change

The daemon loads `main.py` once at startup — code changes do **not** take effect
until the process is restarted. After any edit to `main.py`, restart it:

```bash
pkill -f "main.py"
DISPLAY=:0 setsid /opt/stt/.venv/bin/python main.py >> /tmp/stt-daemon.log 2>&1 < /dev/null &
```

`setsid` detaches it into its own session so it survives the launching shell
closing.

It runs as a plain background process (not systemd), so there is no auto-reload.
Verify the restart took with `tail /tmp/stt-daemon.log` (look for the "ready" line)
and `pgrep -af main.py`.
