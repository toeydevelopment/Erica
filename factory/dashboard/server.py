"""Local fleet dashboard server: python3 server.py [--port N] [--fixture DIR] [--once].

Serves index.html at /, the graph at GET /api/fleet, and edges after a seq at
GET /api/events?after=<seq>. Binds 127.0.0.1 only. --once prints the graph JSON
and exits. --port 0 picks a free port; the bound URL is printed on stdout.
"""

import argparse
import http.server
import json
import os
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import model  # noqa: E402


def make_handler(source):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _send(self, code, body, ctype):
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _json(self, obj):
            self._send(200, json.dumps(obj), "application/json")

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), encoding="utf-8") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            elif url.path == "/api/fleet":
                self._json(source.graph())
            elif url.path == "/api/events":
                q = urllib.parse.parse_qs(url.query)
                try:
                    after = int(q.get("after", ["0"])[0])
                except ValueError:
                    self._send(400, "after must be an integer\n", "text/plain")
                    return
                self._json({"schema": model.SCHEMA, "after": after, "edges": source.events(after)})
            else:
                self._send(404, "not found\n", "text/plain")

        def log_message(self, *args):
            pass

    return Handler


def main():
    p = argparse.ArgumentParser(prog="sf-dashboard")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--fixture")
    p.add_argument("--once", action="store_true")
    p.add_argument("--fm-root", required=True)
    p.add_argument("--fm-home", required=True)
    a = p.parse_args()
    source = model.Source(a.fm_root, a.fm_home, a.fixture)
    if a.once:
        json.dump(source.graph(), sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(source))
    print("sf-dashboard: listening on http://127.0.0.1:%d/" % httpd.server_address[1], flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
