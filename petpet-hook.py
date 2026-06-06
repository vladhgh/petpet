#!/usr/bin/env python3
# petpet-hook.py <event> — map a Claude Code hook event + its stdin JSON into:
#   event.json   {"state","sleep","title","status","color","detail","ttl"}
# title = the session "topic" (тема): the active TodoWrite step if there is a
# plan, else the first user prompt. status/detail are the current activity
# (subtitle); doneness is shown by the card's icon, not the word "Готово".
# Tracks active sessions in session.json so the pet reflects the live session
# and sleeps only when every session has ended. Fast, silent, never fails.
#
# ttl: seconds to keep the card; 0 = sticky (stays until the next event).

import sys, os, json, time

EVENT = sys.argv[1] if len(sys.argv) > 1 else ""
PETPET = os.path.join(os.path.expanduser("~"), "Code/petpet")
SESS_PATH = os.path.join(PETPET, "session.json")
HOME = os.path.expanduser("~")

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

STATE = {"user-prompt": "jumping", "pre": "running",
         "post": "idle", "notify": "waiting", "stop": "waving"}.get(EVENT, "idle")
sleep = False
card = None          # dict {status,color,detail,ttl} or None to leave unchanged
write_event = True   # set False to leave event.json untouched (keep the live card)


def rec(sid):
    return S.setdefault(sid, {"project": base(CWD), "path": short_path(CWD),
                              "topic": "", "ts": time.time(), "busy": False})


def all_idle():
    # The pet sleeps only when no tracked session is busy (working or awaiting
    # input) — so one session finishing never sleeps the pet while another works.
    return not any(v.get("busy") for v in S.values())


if EVENT == "session-start":
    r = rec(SID); r["ts"] = time.time(); r["busy"] = False; sess["active"] = SID
    STATE = "jumping"
    card = {"title": "", "status": "Готов", "color": "green", "detail": r["path"], "ttl": 0}

elif EVENT == "session-end":
    S.pop(SID, None)
    if sess.get("active") == SID:
        sess["active"] = max(S, key=lambda k: S[k]["ts"]) if S else None
    # sleep only once every session has ended or gone idle; either way clear the
    # card so no bubble lingers (if another session still works it re-shows its own).
    STATE, sleep = "idle", all_idle()
    card = {"title": "", "status": "", "color": "gray", "detail": "", "ttl": 0}

else:
    # any of these means the session is live: keep the pet awake and the card
    # sticky (ttl 0) so the status is ALWAYS visible until the next event.
    r = rec(SID); r["ts"] = time.time(); r["busy"] = True; sess["active"] = SID

    if EVENT == "user-prompt":
        prompt = payload.get("prompt", "")
        if prompt and not r.get("topic"):
            r["topic"] = clip(prompt, 40)   # fallback topic until a plan exists
        STATE = "jumping"
        card = {"title": r.get("topic", ""), "status": "Думаю…",
                "color": "purple", "detail": "", "ttl": 0}

    elif EVENT == "pre":
        tool = payload.get("tool_name", "")
        if tool == "TodoWrite":
            topic = active_todo(payload.get("tool_input"))
            if topic:
                r["topic"] = topic          # the plan beats the first-prompt fallback
            STATE = "running"
            card = {"title": r.get("topic", ""), "status": "Планирую",
                    "color": "blue", "detail": "", "ttl": 0}
        else:
            what = describe(tool, payload.get("tool_input"))
            if tool in ("Read", "Grep", "Glob", "NotebookRead", "WebFetch", "WebSearch"):
                STATE = "review"
                card = {"title": r.get("topic", ""), "status": "Читаю",
                        "color": "blue", "detail": what, "ttl": 0}
            else:
                STATE = "running"
                verb = {"Bash": "Выполняю", "Edit": "Редактирую", "MultiEdit": "Редактирую",
                        "Write": "Пишу", "Task": "Запускаю"}.get(tool, "Работаю")
                card = {"title": r.get("topic", ""), "status": verb,
                        "color": "blue", "detail": what,
                        "detail_code": tool == "Bash", "ttl": 0}

    elif EVENT == "post":
        resp = payload.get("tool_response")
        if isinstance(resp, dict) and (resp.get("error") or resp.get("is_error")):
            STATE = "failed"
            card = {"title": r.get("topic", ""), "status": "Ошибка",
                    "color": "red", "detail": "Сбой инструмента", "ttl": 0}
        else:
            # success: leave state + card exactly as the matching `pre` set them —
            # don't rewrite event.json, or the always-on bubble blinks off between tools
            write_event = False

    elif EVENT == "notify":
        STATE = "waiting"
        card = {"title": r.get("topic", ""), "status": "Жду ответа", "color": "amber",
                "detail": clip(payload.get("message") or "Нужен ответ", 60), "ttl": 0}

    elif EVENT == "stop":
        # turn finished → this session is no longer busy. Sleep + clear the card
        # when nothing else is working, so no bubble lingers while the agent idles.
        r["busy"] = False
        STATE = "idle"
        sleep = all_idle()
        card = {"title": "", "status": "", "color": "gray", "detail": "", "ttl": 0}

save_sessions(sess)


if write_event:
    event = {"state": STATE, "sleep": sleep}
    if card is not None:
        event.update(card)
    write_json(os.path.join(PETPET, "event.json"), event)

sys.exit(0)
