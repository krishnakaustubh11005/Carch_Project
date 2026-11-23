#!/usr/bin/env python3
"""Carch program runner: a local web page to write C, then simulate it or run
it on the PYNQ-Z2, on both bitstreams (fpga/user/README.md).

    make user-ui        (or: python3 fpga/user/server.py [--port 8765])
    then open http://localhost:8765 in the Windows browser.

Runs one job at a time in a background thread; the page polls /api/status.
Only listens on 127.0.0.1.
"""
import argparse
import json
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import carch_user as cu

HERE = Path(__file__).resolve().parent
STATE = {"busy": False, "log": [], "result": None, "mode": None}
LOCK = threading.Lock()


def worker(code, mode, max_clocks):
    def logfn(line):
        with LOCK:
            STATE["log"].append(line)
    try:
        res = cu.run_program(code, mode, max_clocks, logfn)
    except Exception as e:  # keep the server alive on unexpected errors
        logfn("ERROR: " + repr(e))
        logfn(traceback.format_exc())
        res = {"error": repr(e), "mode": mode}
    with LOCK:
        STATE["result"] = res
        STATE["busy"] = False


def list_runs():
    out = []
    if cu.RUNS.exists():
        for d in sorted(cu.RUNS.iterdir(), reverse=True)[:40]:
            f = d / "results.json"
            if f.exists():
                try:
                    r = json.loads(f.read_text())
                except ValueError:
                    continue
                first = next((l.strip() for l in (d / "job.c").read_text().splitlines()
                              if l.strip().startswith("//")), "") if (d / "job.c").exists() else ""
                out.append({"run": d.name, "mode": r.get("mode"), "time": r.get("time"),
                            "speedup": r.get("speedup"), "error": r.get("error"),
                            "title": first.lstrip("/ ")[:70]})
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/examples":
            ex = [{"name": f.stem, "code": f.read_text()} for f in sorted((HERE / "examples").glob("*.c"))]
            return self.send(200, ex)
        if path == "/api/runs":
            return self.send(200, list_runs())
        if path.startswith("/api/run/"):
            d = cu.RUNS / Path(path[len("/api/run/"):]).name
            if not (d / "results.json").exists():
                return self.send(404, {"error": "no such run"})
            return self.send(200, {"result": json.loads((d / "results.json").read_text()),
                                   "code": (d / "job.c").read_text()})
        if path == "/api/fpga":
            return self.send(200, cu.fpga_reports())
        if path == "/api/status":
            since = int(self.path.split("since=")[1]) if "since=" in self.path else 0
            with LOCK:
                return self.send(200, {"busy": STATE["busy"], "mode": STATE["mode"],
                                       "log": STATE["log"][since:], "next": len(STATE["log"]),
                                       "result": None if STATE["busy"] else STATE["result"]})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/start":
            return self.send(404, {"error": "not found"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            code, mode = req["code"], req["mode"]
            max_clocks = int(req.get("max_clocks", 3000000))
        except (ValueError, KeyError):
            return self.send(400, {"error": "bad request"})
        if mode not in ("sim", "board"):
            return self.send(400, {"error": "mode must be sim or board"})
        with LOCK:
            if STATE["busy"]:
                return self.send(409, {"error": "a run is already in progress"})
            STATE.update(busy=True, log=[], result=None, mode=mode)
        threading.Thread(target=worker, args=(code, mode, max_clocks), daemon=True).start()
        self.send(200, {"started": True})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"Carch program runner: http://localhost:{a.port}  (Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
