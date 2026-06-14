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
#   petpetctl editor [port]    open the state editor (writes states.json)
#   petpetctl build            recompile from source
#   petpetctl pets             list installed pets

DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="$HOME/.petpet"
BIN="$DATA/petpet"   # build output is a per-machine artifact — lives with the rest of the runtime state, not in the source tree
CONFIG="$DATA/config.json"
EVENT="$DATA/event.json"
LABEL="local.petpet"
PLIST="$DATA/$LABEL.plist"

mkdir -p "$DATA"

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

launch_domain() {
  printf 'gui/%s' "$(id -u)"
}

write_launchd_plist() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/petpet.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/petpet.log</string>
</dict>
</plist>
EOF
}

is_running() {
  launchctl print "$(launch_domain)/$LABEL" 2>/dev/null | grep -q 'pid = '
}

stop_running() {
  launchctl bootout "$(launch_domain)/$LABEL" >/dev/null 2>&1
}

case "$1" in
  start)
    if is_running; then echo "already running"; exit 0; fi
    [ -x "$BIN" ] || { echo "binary missing — run: petpetctl build"; exit 1; }
    write_launchd_plist
    stop_running
    launchctl bootstrap "$(launch_domain)" "$PLIST" >/dev/null 2>&1
    sleep 0.5
    is_running && echo "started" || { echo "failed; see /tmp/petpet.log"; cat /tmp/petpet.log; }
    ;;
  stop)
    stop_running && echo "stopped" || echo "not running"
    ;;
  restart)
    "$0" stop; sleep 0.3; "$0" start
    ;;
  status)
    if is_running; then
      echo "running ($(python3 -c "import json;d=json.load(open('$CONFIG'));print(f\"pet={d.get('pet')}, scale={d.get('scale')}\")" 2>/dev/null))"
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
    printf '{"state":"%s","sleep":false}\n' "$2" > "$EVENT"
    echo "state -> $2"
    ;;
  editor)
    # serve state-editor.html with a writer API so edits persist to states.json
    # (read by the hook) and can preview straight onto the running pet.
    PORT="${2:-7892}"
    if pgrep -f "petpet-editor.py" >/dev/null 2>&1; then
      echo "editor already running"
    else
      cd "$DIR" && nohup python3 petpet-editor.py "$PORT" >/tmp/petpet-editor.log 2>&1 &
      sleep 0.5
    fi
    URL="http://localhost:$PORT/web/state-editor.html"
    echo "editor -> $URL"
    open "$URL" 2>/dev/null || true
    ;;
  build)
    # build to a temp file + mv into place so the binary gets a FRESH inode.
    # Rebuilding in place keeps the old inode, and the kernel's cached code
    # signature then mismatches → launchd kills it with OS_REASON_CODESIGNING.
    swiftc -O "$DIR/PetPet.swift" -o "$DATA/petpet.tmp" \
      && codesign -s - --force "$DATA/petpet.tmp" \
      && mv -f "$DATA/petpet.tmp" "$BIN" \
      && echo "built + signed -> $BIN" || { echo "build failed"; rm -f "$DATA/petpet.tmp"; }
    ;;
  pets)
    for d in "$HOME/.codex/pets"/*/ "$HOME/.petdex/pets"/*/; do
      [ -d "$d" ] || continue
      [ -f "$d/spritesheet.webp" ] || [ -f "$d/spritesheet.png" ] || continue
      basename "$d"
    done | sort -u
    ;;
  *)
    echo "usage: petpetctl {start|stop|restart|status|pet <slug>|scale <n>|state <name>|editor|build|pets}"
    ;;
esac
