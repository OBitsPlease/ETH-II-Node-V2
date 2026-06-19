#!/usr/bin/env python3
"""ETHII gated download service. Serves files from FILES_DIR to holders of valid keys."""
import json
import os
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = "/opt/ethii-downloads"
FILES_DIR = os.path.join(BASE, "files")
KEYS_FILE = os.path.join(BASE, "keys.json")
LOG_FILE = os.path.join(BASE, "download.log")
HOST, PORT = "127.0.0.1", 8090


def load_keys():
    try:
        with open(KEYS_FILE) as f:
            return json.load(f).get("keys", {})
    except (OSError, ValueError):
        return {}


def log(key, label, fname, ip, status):
    line = "%s | %s | %s | %s | %s | %s\n" % (
        datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
        status, key or "-", label or "-", fname or "-", ip or "-")
    with open(LOG_FILE, "a") as f:
        f.write(line)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ethii-dl"

    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def deny(self, code, msg, key=None, fname=None, status="denied"):
        log(key, None, fname, self.client_ip(), status)
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if not url.path.startswith("/dl/"):
            return self.deny(404, "Not found", status="bad-path")
        fname = os.path.basename(url.path[4:])
        if not fname:
            return self.deny(404, "No file specified", status="bad-path")
        key = (parse_qs(url.query).get("key") or [""])[0].strip()
        if not key:
            return self.deny(403, "Missing key. Append ?key=YOUR-KEY", fname=fname, status="denied-nokey")
        keys = load_keys()
        info = keys.get(key)
        if info is None:
            return self.deny(403, "Invalid key", key=key, fname=fname, status="denied-unknown")
        if info.get("revoked"):
            return self.deny(403, "Key has been revoked", key=key, fname=fname, status="denied-revoked")
        fpath = os.path.join(FILES_DIR, fname)
        if not os.path.isfile(fpath):
            return self.deny(404, "Unknown file", key=key, fname=fname, status="denied-nofile")

        size = os.path.getsize(fpath)
        log(key, info.get("label"), fname, self.client_ip(), "download")
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % fname)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(fpath, "rb") as f:
            while True:
                chunk = f.read(1024 * 256)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    log(key, info.get("label"), fname, self.client_ip(), "aborted")
                    return

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(FILES_DIR, exist_ok=True)
    if not os.path.exists(KEYS_FILE):
        with open(KEYS_FILE, "w") as f:
            json.dump({"keys": {}}, f)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
