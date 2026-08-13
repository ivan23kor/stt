#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/home/aivan/.personal/stt"

cd "$REPO_ROOT"
exec "$REPO_ROOT/.venv/bin/python" main.py --speak-stdin
