#!/usr/bin/env python3
"""Minimal MCP server for the mcp-scan tests: one tool, one prompt, standard
library only. `server.py stdio` speaks JSON-RPC over stdin/stdout;
`server.py http PORT` serves the same over Streamable HTTP at /mcp. The
DESCRIPTION environment variable overrides the tool description so a test can
change the tool-description hash."""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOOL = {"name": "echo", "description": os.environ.get("DESCRIPTION", "Echo the input back."),
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}
PROMPT = {"name": "greet", "description": "Say hello."}


def handle(msg):
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        return None  # notification
    results = {
        "initialize": {"protocolVersion": (msg.get("params") or {}).get("protocolVersion", "2025-06-18"),
                       "capabilities": {"tools": {}, "prompts": {}, "resources": {}},
                       "serverInfo": {"name": "fixture", "version": "1.0.0"}},
        "tools/list": {"tools": [TOOL]},
        "prompts/list": {"prompts": [PROMPT]},
        "resources/list": {"resources": []},
        "resources/templates/list": {"resourceTemplates": []},
        "ping": {},
    }
    if method in results:
        return {"jsonrpc": "2.0", "id": rid, "result": results[method]}
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"unknown method {method}"}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or b"{}"))
        reply = handle(body)
        if reply is None:
            self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_response(405); self.send_header("Content-Length", "0"); self.end_headers()

    def do_DELETE(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()


if __name__ == "__main__":
    if sys.argv[1] == "http":
        HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
    for line in sys.stdin:
        if line.strip():
            reply = handle(json.loads(line))
            if reply is not None:
                sys.stdout.write(json.dumps(reply) + "\n"); sys.stdout.flush()
