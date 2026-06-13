#!/bin/sh
# Thin wrapper so settings.json can stay stable: hand the event + stdin
# payload to the Python hook. exec preserves stdin from Claude Code.
PY="$(command -v python3 || echo /usr/bin/python3)"
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$PY" "$DIR/petpet-hook.py" "$1"
