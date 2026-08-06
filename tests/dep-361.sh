#!/usr/bin/env bash
set -eu

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v python3 >/dev/null 2>&1; then
  python3 "$repo_root/tests/dep-361.py"
elif command -v python >/dev/null 2>&1; then
  python "$repo_root/tests/dep-361.py"
else
  echo "FAIL: python or python3 not found" >&2
  exit 1
fi
