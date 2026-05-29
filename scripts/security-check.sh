#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

echo "security-check: syntax"
.venv/bin/python -m py_compile main.py

echo "security-check: generated files"
if git ls-files | rg -n '(^|/)__pycache__/|\.py[co]$'; then
  echo "Generated Python cache files must not be committed." >&2
  exit 1
fi

secret_pattern='(gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,}|gsk_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN (RSA|DSA|EC|OPENSSH|PRIVATE) PRIVATE KEY-----)'
private_terms="(clo""sact|reg""hub|pp""sa)"

echo "security-check: staged diff secrets"
if git diff --cached --text --unified=0 | rg -n -i "$secret_pattern|$private_terms"; then
  echo "Potential secret or private project term found in staged diff." >&2
  exit 1
fi

echo "security-check: working tree secrets"
if rg -n --hidden \
  --glob '!/.git/**' \
  --glob '!/.venv/**' \
  --glob '!uv.lock' \
  --glob '!__pycache__/**' \
  -i "$secret_pattern|$private_terms" .; then
  echo "Potential secret or private project term found in working tree." >&2
  exit 1
fi

echo "security-check: committed history secrets"
if git log -p --all -- . ':(exclude)uv.lock' | rg -n -i "$secret_pattern|$private_terms"; then
  echo "Potential secret or private project term found in Git history." >&2
  exit 1
fi

echo "security-check: semgrep secrets"
semgrep --config=p/secrets --error --quiet .

echo "security-check: dependency audit"
uvx pip-audit --path .venv
