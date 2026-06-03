#!/bin/sh
# petpetctl — control the PetPet mascot.
#
#   petpetctl start            launch the mascot
#   petpetctl stop             quit it
#   petpetctl restart          rebuild-free restart
#   petpetctl status           is it running?
#   petpetctl pet <slug>       switch pet (e.g. minatonamikaze, itachi)
#   petpetctl scale <n>        set size multiplier (e.g. 3)
#   petpetctl state <name>     manually set animation state
#   petpetctl build            recompile from source
#   petpetctl pets             list installed pets

DIR="$HOME/Code/petpet"
BIN="$DIR/petpet"
CONFIG="$DIR/config.json"
STATE="$DIR/state.json"

set_json_key() {  # set_json_key <key> <raw-json-value>
  python3 - "$CONFIG" "$1" "$2" <<'PY'
import json, sys
path, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    obj = json.load(open(path))
except Exception:
    obj = {}
try:
    val = json.loads(raw)
except Exception:
    val = raw
obj[key] = val
json.dump(obj, open(path, "w"), indent=2)
PY
}

case "$1" in
  start)
    if pgrep -f "$BIN" >/dev/null 2>&1; then echo "already running"; exit 0; fi
    [ -x "$BIN" ] || { echo "binary missing — run: petpetctl build"; exit 1; }
    nohup "$BIN" >/tmp/petpet.log 2>&1 &
    sleep 0.5
    pgrep -f "$BIN" >/dev/null 2>&1 && echo "started" || { echo "failed; see /tmp/petpet.log"; cat /tmp/petpet.log; }
    ;;
  stop)
    pkill -f "$BIN" 2>/dev/null && echo "stopped" || echo "not running"
    ;;
  restart)
    "$0" stop; sleep 0.3; "$0" start
    ;;
  status)
    if pgrep -f "$BIN" >/dev/null 2>&1; then
      echo "running (pet=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('pet'))" 2>/dev/null), scale=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('scale'))" 2>/dev/null))"
    else
      echo "stopped"
    fi
    ;;
  pet)
    [ -z "$2" ] && { echo "usage: petpetctl pet <slug>"; exit 1; }
    set_json_key pet "\"$2\""
    echo "pet -> $2"
    "$0" restart
    ;;
  scale)
    [ -z "$2" ] && { echo "usage: petpetctl scale <n>"; exit 1; }
    set_json_key scale "$2"
    echo "scale -> $2"
    "$0" restart
    ;;
  state)
    [ -z "$2" ] && { echo "usage: petpetctl state <name>"; exit 1; }
    printf '{"state":"%s"}\n' "$2" > "$STATE"
    echo "state -> $2"
    ;;
  build)
    # build to a temp file + mv into place so the binary gets a FRESH inode.
    # Rebuilding in place keeps the old inode, and the kernel's cached code
    # signature then mismatches → launchd kills it with OS_REASON_CODESIGNING.
    cd "$DIR" \
      && swiftc -O PetPet.swift -o petpet.tmp \
      && codesign -s - --force petpet.tmp \
      && mv -f petpet.tmp petpet \
      && echo "built + signed" || { echo "build failed"; rm -f "$DIR/petpet.tmp"; }
    ;;
  pets)
    for d in "$HOME/.codex/pets"/*/ "$HOME/.petdex/pets"/*/; do
      [ -d "$d" ] || continue
      [ -f "$d/spritesheet.webp" ] || [ -f "$d/spritesheet.png" ] || continue
      basename "$d"
    done | sort -u
    ;;
  *)
    echo "usage: petpetctl {start|stop|restart|status|pet <slug>|scale <n>|state <name>|build|pets}"
    ;;
esac
