#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
if [ "$action" != "toggle" ] && [ "$action" != "stop" ]; then
  printf 'usage: %s {toggle|stop}\n' "$0" >&2
  exit 2
fi

tts_pids=()
while IFS= read -r candidate_pid; do
  [ -n "$candidate_pid" ] || continue
  command_line="$(tr '\0' ' ' < "/proc/$candidate_pid/cmdline" 2>/dev/null || true)"
  case "$command_line" in
    mpv*"--title=tts-audio"*) tts_pids+=("$candidate_pid") ;;
  esac
done < <(pgrep -x mpv || true)

request_pids=()
while IFS= read -r request_pid; do
  [ -n "$request_pid" ] && request_pids+=("$request_pid")
done < <(pgrep -f '^/home/aivan/.personal/stt/.venv/bin/python main.py --speak-stdin$' || true)

if [ "$action" = "stop" ]; then
  if [ "${#tts_pids[@]}" -eq 0 ] && [ "${#request_pids[@]}" -eq 0 ]; then
    printf 'not-playing\n'
    exit 0
  fi
  if [ "${#tts_pids[@]}" -gt 0 ]; then
    kill -TERM "${tts_pids[@]}"
  fi
  if [ "${#request_pids[@]}" -gt 0 ]; then
    kill -TERM "${request_pids[@]}"
  fi
  printf 'stopped\n'
  exit 0
fi

if [ "${#tts_pids[@]}" -eq 0 ]; then
  printf 'not-playing\n'
  exit 0
fi

is_paused=false
for playback_pid in "${tts_pids[@]}"; do
  process_state="$(ps -o stat= -p "$playback_pid" 2>/dev/null || true)"
  case "$process_state" in
    T*) is_paused=true; break ;;
  esac
done

if [ "$is_paused" = true ]; then
  kill -CONT "${tts_pids[@]}"
  printf 'resumed\n'
else
  kill -STOP "${tts_pids[@]}"
  printf 'paused\n'
fi
