#!/usr/bin/env python3
# petpet-hook.py <event> — map a Claude Code hook event + its stdin JSON into:
#   event.json   {"state","sleep","title","status","color","detail","ttl"}
# title = the session "topic" (тема): the active TodoWrite step if there is a
# plan, else the first user prompt. status/detail are the current activity
# (subtitle); doneness is shown by the card's icon, not the word "Готово".
#
# Multi-session model: every session keeps its OWN render (phase/state/card) in
# session.json. event.json is then recomputed as whichever session "wins" by
# phase priority (waiting > working > ready > finished > idle), so a background
# session that just started or finished never steals the bubble from one that's
# still working, and the pet sleeps only when EVERY session is idle.
# Fast, silent, never fails.
#
# ttl: seconds to keep the card; 0 = sticky (stays until the next event).
# A "finished" session emits sleep_after=GRACE so the pet shows "Готово" for a
# moment before dozing, instead of blinking straight to sleep.

import sys, os, json, time

EVENT = sys.argv[1] if len(sys.argv) > 1 else ""
PETPET = os.path.join(os.path.expanduser("~"), "Code/petpet")
SESS_PATH = os.path.join(PETPET, "session.json")
EVENT_PATH = os.path.join(PETPET, "event.json")
HOME = os.path.expanduser("~")
GRACE = 6.0   # seconds a finished session lingers on "Готово" before sleeping

if os.path.exists(os.path.join(PETPET, "hooks-disabled")):
    sys.exit(0)

payload = {}
try:
    raw = sys.stdin.read()
    if raw.strip():
        payload = json.loads(raw)
except Exception:
    payload = {}

SID = payload.get("session_id") or "default"
CWD = payload.get("cwd") or os.getcwd()


def base(p):
    return os.path.basename(str(p).rstrip("/")) or str(p)


def clip(s, n=44):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def short_path(cwd):
    p = cwd or HOME
    if p == HOME:
        return "~"
    if p.startswith(HOME + "/"):
        comps = [c for c in p[len(HOME) + 1:].split("/") if c]
        return "~/" + "/".join(comps[-2:]) if len(comps) <= 2 else "…/" + "/".join(comps[-2:])
    comps = [c for c in p.split("/") if c]
    return "/" + "/".join(comps) if len(comps) <= 2 else "…/" + "/".join(comps[-2:])


def describe(tool, ti):
    if not isinstance(ti, dict):
        ti = {}
    t = tool or ""
    if t == "Bash":         return clip(ti.get("command", ""))
    if t in ("Edit", "MultiEdit"): return base(ti.get("file_path", "?"))
    if t == "Write":        return base(ti.get("file_path", "?"))
    if t == "Read":         return base(ti.get("file_path", "?"))
    if t == "NotebookEdit": return base(ti.get("notebook_path", "notebook"))
    if t == "Grep":         return clip(ti.get("pattern", ""))
    if t == "Glob":         return clip(ti.get("pattern", "files"))
    if t in ("WebFetch", "WebSearch"): return "the web"
    if t == "Task":         return "a subagent"
    if t == "TodoWrite":    return "the plan"
    if t.startswith("mcp__"): return clip(t.split("__")[-1].replace("_", " "))
    return clip(t) if t else ""


def active_todo(ti):
    # The in-progress TodoWrite item is literally "what we're doing now" — the
    # best available "topic" for the card title. activeForm is the present-tense
    # phrasing ("Чищу Downloads"); fall back to content.
    if not isinstance(ti, dict):
        return ""
    todos = ti.get("todos")
    if not isinstance(todos, list):
        return ""
    for td in todos:
        if isinstance(td, dict) and td.get("status") == "in_progress":
            return clip(td.get("activeForm") or td.get("content") or "", 40)
    return ""


# ---- session bookkeeping ---------------------------------------------------

def write_json(path, obj):
    try:
        with open(path, "w") as f:
            json.dump(obj, f)
    except Exception:
        pass


def load_sessions():
    try:
        with open(SESS_PATH) as f:
            d = json.load(f)
        d.setdefault("sessions", {})
        return d
    except Exception:
        return {"sessions": {}, "active": None}


def save_sessions(d):
    write_json(SESS_PATH, d)


sess = load_sessions()
S = sess["sessions"]


def rec(sid):
    return S.setdefault(sid, {"project": base(CWD), "path": short_path(CWD),
                              "topic": "", "ts": time.time(),
                              "phase": "idle", "state": "idle", "card": None})


def render(r, phase, state, card):
    # Record this session's latest render. phase drives who wins the bubble;
    # state is the animation; card is the bubble (or None for nothing to show).
    r["phase"] = phase
    r["state"] = state
    r["card"] = card
    r["ts"] = time.time()
    sess["active"] = SID


# ---- one session changed: update its record ---------------------------------

if EVENT == "session-start":
    r = rec(SID)
    render(r, "ready", "waving",
           {"title": "", "status": "Новая сессия", "color": "green",
            "detail": r["path"], "ttl": 4})

elif EVENT == "session-end":
    S.pop(SID, None)
    if sess.get("active") == SID:
        sess["active"] = max(S, key=lambda k: S[k]["ts"]) if S else None

elif EVENT == "user-prompt":
    r = rec(SID)
    prompt = payload.get("prompt", "")
    if prompt and not r.get("topic"):
        r["topic"] = clip(prompt, 40)       # fallback topic until a plan exists
    render(r, "working", "jumping",
           {"title": r.get("topic", ""), "status": "Думаю…",
            "color": "purple", "detail": "", "ttl": 0})

elif EVENT == "pre":
    r = rec(SID)
    tool = payload.get("tool_name", "")
    if tool == "TodoWrite":
        topic = active_todo(payload.get("tool_input"))
        if topic:
            r["topic"] = topic              # the plan beats the first-prompt fallback
        render(r, "working", "running",
               {"title": r.get("topic", ""), "status": "Планирую",
                "color": "blue", "detail": "", "ttl": 0})
    else:
        what = describe(tool, payload.get("tool_input"))
        if tool in ("Read", "Grep", "Glob", "NotebookRead", "WebFetch", "WebSearch"):
            render(r, "working", "review",
                   {"title": r.get("topic", ""), "status": "Читаю",
                    "color": "blue", "detail": what, "ttl": 0})
        else:
            verb = {"Bash": "Выполняю", "Edit": "Редактирую", "MultiEdit": "Редактирую",
                    "Write": "Пишу", "Task": "Запускаю"}.get(tool, "Работаю")
            render(r, "working", "running",
                   {"title": r.get("topic", ""), "status": verb,
                    "color": "blue", "detail": what,
                    "detail_code": tool == "Bash", "ttl": 0})

elif EVENT == "post":
    r = rec(SID)
    resp = payload.get("tool_response")
    if isinstance(resp, dict) and (resp.get("error") or resp.get("is_error")):
        render(r, "working", "failed",
               {"title": r.get("topic", ""), "status": "Ошибка",
                "color": "red", "detail": "Сбой инструмента", "ttl": 0})
    # success: leave the session's render exactly as the matching `pre` set it —
    # rebuilding the same card unchanged keeps the always-on bubble from blinking.

elif EVENT == "notify":
    r = rec(SID)
    render(r, "waiting", "waiting",
           {"title": r.get("topic", ""), "status": "Жду ответа", "color": "amber",
            "detail": clip(payload.get("message") or "Нужен ответ", 60), "ttl": 0})

elif EVENT == "stop":
    # turn finished → linger on "Готово". The pet only actually sleeps if this
    # session wins the render below, and then only after GRACE (via sleep_after).
    r = rec(SID)
    render(r, "finished", "waving",
           {"title": "", "status": "Готово", "color": "green", "detail": "", "ttl": 0})

save_sessions(sess)


# ---- recompute event.json: whichever session wins drives the pet ------------

def tier(r):
    # higher = more deserving of the bubble. finished decays to idle after GRACE.
    ph = r.get("phase", "idle")
    if ph == "waiting":  return 4
    if ph == "working":  return 3
    if ph == "ready":    return 2
    if ph == "finished": return 1 if (time.time() - r.get("ts", 0)) < GRACE else 0
    return 0


def build_event():
    idle = {"state": "idle", "sleep": True, "title": "", "status": "",
            "color": "gray", "detail": "", "ttl": 0}
    if not S:
        return idle
    r = S[max(S, key=lambda k: (tier(S[k]), S[k].get("ts", 0)))]
    t = tier(r)
    if t == 0 or not r.get("card"):
        return idle
    event = {"state": r.get("state", "idle"), "sleep": False}
    event.update(r["card"])
    if t == 1:                       # finished: show "Готово", then doze off
        event["sleep_after"] = GRACE
    return event


event = build_event()

# Skip the write if nothing actually changed — an unchanged event.json keeps the
# bubble (and its spinner) from flickering between back-to-back tool events.
try:
    with open(EVENT_PATH) as f:
        if json.load(f) == event:
            sys.exit(0)
except Exception:
    pass

write_json(EVENT_PATH, event)
sys.exit(0)
