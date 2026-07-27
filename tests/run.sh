#!/usr/bin/env bash
# Offline, non-privileged test entrypoint. It never installs or launches xray.
set -eu

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

cd "$TEST_ROOT"

"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 9), "Python 3.9+ required"'
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest discover \
  -s tests \
  -p 'test_*.py' \
  -v
