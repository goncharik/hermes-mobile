#!/usr/bin/env python3
"""Throwaway stand-in for the gateway's /auth/native/authorize endpoint.

`GET /authorize?redirect_uri=<loopback>&state=<s>&code=<c>` answers 302 to
`<redirect_uri>?code=<c>&state=<s>`, exactly like the Hermes gateway does once the
portal login completes. Every request is logged so we can tell whether the Safari view
service actually reached us.

Usage: python3 redirect_server.py [port]
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        print(f"[authorize-server] GET {self.path} ua={self.headers.get('User-Agent')}", flush=True)
        if parsed.path != "/authorize":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        redirect_uri = query.get("redirect_uri", [""])[0]
        state = query.get("state", [""])[0]
        code = query.get("code", ["spike-code"])[0]
        if not redirect_uri:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        sep = "&" if "?" in redirect_uri else "?"
        location = f"{redirect_uri}{sep}code={code}&state={state}"
        print(f"[authorize-server] 302 -> {location}", flush=True)
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):  # silence the default stderr noise
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    print(f"[authorize-server] listening on 127.0.0.1:{port}", flush=True)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
