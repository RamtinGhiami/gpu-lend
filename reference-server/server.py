#!/usr/bin/env python3
"""A tiny reference server for the GPU Lend protocol (see ../PROTOCOL.md). Standard library only.

    python server.py --port 8780

It prints a pairing text and an admin key. Paste the pairing text into the app (Server tab). Then any program can send work to the
paired PCs:

    curl -s http://127.0.0.1:8780/submit -H "X-Admin-Key: <key>" -d '{"backend":"llm","path":"/v1/chat/completions",
         "body":{"messages":[{"role":"user","content":"Hello"}]}}'

The app only talks to https:// servers (or http://localhost for testing), so put a TLS proxy such as Caddy or nginx in front of this
for real use. State is kept in memory: restarting the server pairs devices again.
"""
import argparse
import base64
import json
import queue
import secrets
import string
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOLD_SECONDS = 20  # how long GET /worker/next waits for a job
JOB_TIMEOUT = 600  # how long /submit waits for the answer


class State:
    def __init__(self, public_url):
        self.public_url = public_url
        self.admin_key = secrets.token_urlsafe(18)
        self.code = "".join(secrets.choice(string.ascii_uppercase) for _ in range(8))
        self.workers = {}  # token -> {"id", "name", "backends", "seen"}
        self.jobs = queue.Queue()  # (id, backend, path, body)
        self.results = {}  # job id -> {"event", "status", "body"}
        self.lock = threading.Lock()
        self.next_worker = 1

    def pairing_text(self):
        raw = json.dumps({"u": self.public_url, "ip": "", "fp": "", "c": self.code}).encode()
        return "GLEND1." + base64.urlsafe_b64encode(raw).decode().rstrip("=")


class Handler(BaseHTTPRequestHandler):
    state = None  # set in main()
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # ---- helpers
    def _body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            data = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, status, body=b"", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            headers = {"Content-Type": "application/json", **(headers or {})}
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _worker(self):
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        w = self.state.workers.get(token)
        if w:
            w["seen"] = time.time()
        return w

    # ---- device endpoints
    def do_POST(self):
        s = self.state
        path = self.path.split("?")[0]
        if path == "/worker/pair":
            j = json.loads(self._body() or b"{}")
            if j.get("code") != s.code:
                return self._send(401, {"error": "wrong code"})
            token = secrets.token_hex(32)
            with s.lock:
                wid = s.next_worker
                s.next_worker += 1
                s.workers[token] = {"id": wid, "name": j.get("name", ""), "backends": ["image"], "seen": time.time()}
                s.code = "".join(secrets.choice(string.ascii_uppercase) for _ in range(8))  # one use only
            print(f"paired device {wid} ({j.get('name', '')}); next pairing text:\n{s.pairing_text()}")
            return self._send(200, {"token": token, "worker_id": wid, "settings": self._settings(wid, j.get("name", ""))})
        if path == "/worker/heartbeat":
            w = self._worker()
            if not w:
                return self._send(401, {"error": "unknown device"})
            j = json.loads(self._body() or b"{}")
            w["backends"] = j.get("backends") or ["image"]
            return self._send(200, {"settings": self._settings(w["id"], w["name"]), "latest_version": ""})
        if path.startswith("/worker/result/"):
            w = self._worker()
            if not w:
                return self._send(401, {"error": "unknown device"})
            job = path.rsplit("/", 1)[1]
            data = self._body()
            r = s.results.get(job)
            if not r:
                return self._send(403, {"error": "not your job"})
            r["status"] = int(self.headers.get("x-lend-status", "200"))
            r["body"] = data
            r["event"].set()
            return self._send(204)
        if path == "/submit":
            if self.headers.get("X-Admin-Key") != s.admin_key:
                return self._send(401, {"error": "admin key needed"})
            j = json.loads(self._body() or b"{}")
            job_id = secrets.token_hex(6)
            entry = {"event": threading.Event(), "status": 0, "body": b""}
            s.results[job_id] = entry
            s.jobs.put((job_id, j.get("backend", "image"), j.get("path", ""), json.dumps(j.get("body", {})).encode()))
            if not entry["event"].wait(JOB_TIMEOUT):
                s.results.pop(job_id, None)
                return self._send(504, {"error": "no device took the job in time"})
            s.results.pop(job_id, None)
            return self._send(entry["status"], entry["body"], {"Content-Type": "application/json"})
        self._send(404, {"error": "not found"})

    def do_GET(self):
        s = self.state
        if self.path.split("?")[0] == "/worker/next":
            w = self._worker()
            if not w:
                return self._send(401, {"error": "unknown device"})
            try:
                job_id, backend, path, body = s.jobs.get(timeout=HOLD_SECONDS)
            except queue.Empty:
                return self._send(204)
            if backend not in w["backends"]:
                s.jobs.put((job_id, backend, path, body))  # not for this device
                time.sleep(1)
                return self._send(204)
            return self._send(200, body, {"x-lend-job": job_id, "x-lend-path": path, "x-lend-backend": backend, "Content-Type": "application/json"})
        self._send(404, {"error": "not found"})

    @staticmethod
    def _settings(wid, name):
        return {"name": name or f"Device {wid}", "enabled": True, "max_vram": 5.4, "hour_from": 0, "hour_to": 24, "ac_only": False,
                "autostart": True, "daily_minutes": 0, "daily_jobs": 0, "rev": 1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8780)
    ap.add_argument("--public-url", default="", help="the https address devices use (default http://127.0.0.1:PORT)")
    a = ap.parse_args()
    state = State(a.public_url or f"http://127.0.0.1:{a.port}")
    Handler.state = state
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"GPU Lend reference server on 127.0.0.1:{a.port}")
    print(f"admin key : {state.admin_key}")
    print(f"pairing   : {state.pairing_text()}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
