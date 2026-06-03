#!/bin/sh
# Thin wrapper so settings.json can stay stable: hand the event + stdin
# payload to the Python hook. exec preserves stdin from Claude Code.
PY="$(command -v python3 || echo /usr/bin/python3)"
exec "$PY" "$HOME/Code/petpet/petpet-hook.py" "$1"
