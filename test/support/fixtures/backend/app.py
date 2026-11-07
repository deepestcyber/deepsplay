"""A small backend for the tests of Deepsplay.Backend (stdlib only)."""
import json
import os
import resource
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/crash":
            os._exit(3)
        if path == "/echo":
            body = json.dumps({"path": self.path, "accept": self.headers.get("Accept")}).encode()
        elif path == "/health":
            body = b"ok"
        elif path == "/env":
            body = json.dumps(dict(os.environ)).encode()
        elif path == "/limit":
            body = json.dumps(resource.getrlimit(resource.RLIMIT_AS)).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.send_response(201)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"got " + body)

    def log_message(self, *args):
        pass


print("starting on", sys.argv[1], flush=True)
HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
