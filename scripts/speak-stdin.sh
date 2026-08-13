#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/home/aivan/.personal/stt"
LOCUTOR_ENV="/home/aivan/.personal/Locutor/.env"

if [ ! -f "$LOCUTOR_ENV" ]; then
  printf 'Locutor environment file not found: %s\n' "$LOCUTOR_ENV" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$LOCUTOR_ENV"
set +a

cd "$REPO_ROOT"
exec "$REPO_ROOT/.venv/bin/python" main.py --speak-stdin
