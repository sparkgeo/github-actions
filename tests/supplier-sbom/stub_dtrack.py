"""Stand-in for Dependency-Track in tests/supplier-sbom/run.sh: accepts
PUT /api/v1/bom and /api/v1/vex, writes each request (API key header and
JSON body) to <dir>/<endpoint>.json, and answers like the real API.

Usage: stub_dtrack.py <dir> (prints the port it listens on)
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

OUT = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):  # pylint: disable=invalid-name  # http.server dispatches on this name
        endpoint = self.path.rsplit("/", 1)[-1]
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        (OUT / f"{endpoint}.json").write_text(json.dumps({"api_key": self.headers.get("X-Api-Key"), "body": body}))
        reply = json.dumps({"token": "00000000-0000-0000-0000-000000000000"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
