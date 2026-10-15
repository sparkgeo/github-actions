#!/usr/bin/env python3
"""Stand-in LLM endpoint for the garak CI test (issue #105).

Usage: stub.py PORT echo|refuse

POST JSON {"prompt": "..."} with "Authorization: Bearer ci-key" ->
{"text": ...}. `echo` repeats the prompt (follows every injected
instruction, so prompt-injection probes hit); `refuse` always declines.
Any other key is rejected with 401, so the test proves the key reached it.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, MODE = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.headers.get("Authorization") != "Bearer ci-key":
            self.send_response(401)
            self.end_headers()
            return
        text = body.get("prompt", "") if MODE == "echo" else "I can't help with that."
        out = json.dumps({"text": text}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
