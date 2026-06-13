#!/usr/bin/env python3
# petpet-editor.py — tiny static server for state-editor.html that can also
# WRITE back into the file-based contract:
#   GET  /api/states  → current states.json (the editor's saved overrides)
#   POST /api/states  → overwrite states.json (atomic) — the hook reads it on
#                       its next event, so edits take effect on the next tool call
#   POST /api/event   → overwrite event.json — pushes a one-shot preview straight
#                       to the running pet (it polls event.json every 0.2s)
# Everything else is served as static files from the repo dir (so /state-editor
# .html, /sprite-viewer.html and /pets/<slug>/spritesheet.webp all just work).
#
# Single-user localhost tool: bound to 127.0.0.1, no auth, intentionally tiny.

import json, os, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(os.path.expanduser("~"), ".petpet")
STATES_PATH = os.path.join(DATA_DIR, "states.json")
EVENT_PATH = os.path.join(DATA_DIR, "event.json")
os.makedirs(DATA_DIR, exist_ok=True)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7892
PET_BASES = [
    os.path.join(os.path.expanduser("~"), ".codex", "pets"),
    os.path.join(os.path.expanduser("~"), ".petdex", "pets"),
]


def write_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a):
        pass  # quiet

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/states":
            try:
                with open(STATES_PATH) as f:
                    data = json.load(f)
            except Exception:
                data = {}
            return self._json(200, data)
        if path.startswith("/pets/"):
            parts = [unquote(p) for p in path.split("/") if p]
            if len(parts) == 3 and parts[2] in ("spritesheet.webp", "spritesheet.png"):
                for base in PET_BASES:
                    pet_path = os.path.join(base, parts[1], parts[2])
                    if os.path.isfile(pet_path):
                        self.path = pet_path
                        return self.send_head_file(pet_path)
                self.send_error(404, "pet spritesheet not found")
                return
        return super().do_GET()

    def send_head_file(self, path):
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "file not found")
            return None
        fs = os.fstat(f.fileno())
        ctype = self.guess_type(path)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(fs.st_size))
        self.send_header("Last-Modified", self.date_time_string(fs.st_mtime))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.copyfile(f, self.wfile)
        f.close()
        return None

    def do_POST(self):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            return self._json(400, {"ok": False, "error": "bad json"})
        if path == "/api/states":
            write_atomic(STATES_PATH, body)
            return self._json(200, {"ok": True})
        if path == "/api/event":
            write_atomic(EVENT_PATH, body)
            return self._json(200, {"ok": True})
        return self._json(404, {"ok": False, "error": "not found"})


if __name__ == "__main__":
    os.chdir(ROOT)
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"petpet-editor on http://localhost:{PORT}/state-editor.html")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
