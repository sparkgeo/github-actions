"""Deliberately vulnerable API for tests/dast-api (issue #67). Never deploy.

GET /openapi.json  the OpenAPI 3 definition beside this file (no auth needed)
GET /api/items?name= answers with a MySQL syntax error whenever name holds a
                   quote, the way string-built SQL does (error-based SQL
                   injection). Only when the X-Fixture-Token header matches
                   FIXTURE_TOKEN, so a finding there proves the scan sent the
                   auth header.

Usage: FIXTURE_TOKEN=... python3 app.py [port]
"""

import html
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ.get("FIXTURE_TOKEN", "")
SPEC = json.loads((Path(__file__).parent / "openapi.json").read_text())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # pylint: disable=invalid-name  # http.server dispatches on this name
        url = urlparse(self.path)
        if url.path == "/openapi.json":
            self.reply(200, "application/json", json.dumps(SPEC))
        elif url.path == "/api/items":
            if not TOKEN or self.headers.get("X-Fixture-Token") != TOKEN:
                self.reply(401, "text/plain", "missing or wrong X-Fixture-Token")
                return
            name = parse_qs(url.query).get("name", [""])[0]
            # The flaw under test: a quote breaks the (simulated) SQL string.
            if "'" in name:
                self.reply(500, "text/html", "<html><body>You have an error in your SQL syntax; check the manual that "
                           "corresponds to your MySQL server version for the right syntax to use near "
                           f"'{html.escape(name)}' at line 1</body></html>")
            else:
                self.reply(200, "application/json", json.dumps({"items": [], "name": name}))
        else:
            self.reply(404, "text/plain", "not found")

    def reply(self, status, content_type, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8082), Handler).serve_forever()
