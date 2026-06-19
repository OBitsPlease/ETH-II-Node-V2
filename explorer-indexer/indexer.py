#!/usr/bin/env python3
"""ETHII address-history indexer.

Walks the chain via the local node RPC, stores blocks and transactions in
SQLite, and serves paginated per-address history on 127.0.0.1:8091.

  GET /address-history?addr=0x...&kind=blocks|txs&page=1
    -> {"total": N, "page": 1, "pages": M, "pageSize": 20, "rows": [...]}
"""
import json
import sqlite3
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

RPC_URL = "http://91.99.231.217:8545"
DB_PATH = "/opt/ethii-explorer/index.db"
LISTEN = ("127.0.0.1", 8091)
PAGE_SIZE = 20
REORG_DEPTH = 12
POLL_SECONDS = 10


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())["result"]


def open_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(
        "CREATE TABLE IF NOT EXISTS blocks ("
        "number INTEGER PRIMARY KEY, hash TEXT, miner TEXT, ts INTEGER, txcount INTEGER)"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS txs ("
        "hash TEXT PRIMARY KEY, block INTEGER, ts INTEGER,"
        "sender TEXT, recipient TEXT, value TEXT)"
    )
    db.execute("CREATE INDEX IF NOT EXISTS idx_blocks_miner ON blocks(miner)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_txs_sender ON txs(sender)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_txs_recipient ON txs(recipient)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_txs_block ON txs(block)")
    return db


def index_block(db, num):
    b = rpc("eth_getBlockByNumber", [hex(num), True])
    if not b:
        return False
    ts = int(b["timestamp"], 16)
    txs = b.get("transactions") or []
    db.execute("DELETE FROM txs WHERE block=?", (num,))
    db.execute(
        "INSERT OR REPLACE INTO blocks (number, hash, miner, ts, txcount) VALUES (?,?,?,?,?)",
        (num, b["hash"].lower(), (b.get("miner") or "").lower(), ts, len(txs)),
    )
    for t in txs:
        db.execute(
            "INSERT OR REPLACE INTO txs (hash, block, ts, sender, recipient, value) VALUES (?,?,?,?,?,?)",
            (
                t["hash"].lower(),
                num,
                ts,
                (t.get("from") or "").lower(),
                (t.get("to") or "").lower(),
                str(int(t.get("value") or "0x0", 16)),
            ),
        )
    return True


def indexer_loop():
    db = open_db()
    while True:
        try:
            tip = int(rpc("eth_blockNumber", []), 16)
            row = db.execute("SELECT MAX(number) FROM blocks").fetchone()
            last = row[0] if row[0] is not None else -1

            # rewind on reorg: confirm stored hashes still match the chain
            start = max(0, last - REORG_DEPTH + 1)
            for n in range(start, last + 1):
                stored = db.execute("SELECT hash FROM blocks WHERE number=?", (n,)).fetchone()
                if stored is None:
                    continue
                live = rpc("eth_getBlockByNumber", [hex(n), False])
                if not live or live["hash"].lower() != stored[0]:
                    db.execute("DELETE FROM blocks WHERE number>=?", (n,))
                    db.execute("DELETE FROM txs WHERE block>=?", (n,))
                    last = n - 1
                    break

            n = last + 1
            while n <= tip:
                if not index_block(db, n):
                    break
                if n % 500 == 0:
                    db.commit()
                    print(f"indexed up to block {n}", flush=True)
                n += 1
            db.commit()
        except Exception as e:
            print(f"indexer error: {e}", flush=True)
        time.sleep(POLL_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/address-history":
            self._json(404, {"error": "not found"})
            return
        q = parse_qs(url.query)
        addr = (q.get("addr", [""])[0]).strip().lower()
        kind = q.get("kind", ["blocks"])[0]
        try:
            page = max(1, int(q.get("page", ["1"])[0]))
        except ValueError:
            page = 1
        if len(addr) != 42 or not addr.startswith("0x"):
            self._json(400, {"error": "bad address"})
            return

        db = sqlite3.connect(DB_PATH)
        try:
            off = (page - 1) * PAGE_SIZE
            if kind == "txs":
                total = db.execute(
                    "SELECT COUNT(*) FROM txs WHERE sender=? OR recipient=?", (addr, addr)
                ).fetchone()[0]
                rows = db.execute(
                    "SELECT hash, block, ts, sender, recipient, value FROM txs "
                    "WHERE sender=? OR recipient=? ORDER BY block DESC, hash LIMIT ? OFFSET ?",
                    (addr, addr, PAGE_SIZE, off),
                ).fetchall()
                out = [
                    {"hash": r[0], "block": r[1], "ts": r[2], "from": r[3], "to": r[4], "value": r[5]}
                    for r in rows
                ]
            else:
                total = db.execute(
                    "SELECT COUNT(*) FROM blocks WHERE miner=?", (addr,)
                ).fetchone()[0]
                rows = db.execute(
                    "SELECT number, hash, ts, txcount FROM blocks "
                    "WHERE miner=? ORDER BY number DESC LIMIT ? OFFSET ?",
                    (addr, PAGE_SIZE, off),
                ).fetchall()
                out = [{"number": r[0], "hash": r[1], "ts": r[2], "txCount": r[3]} for r in rows]
            pages = max(1, -(-total // PAGE_SIZE))
            self._json(200, {"total": total, "page": page, "pages": pages, "pageSize": PAGE_SIZE, "rows": out})
        finally:
            db.close()


def main():
    threading.Thread(target=indexer_loop, daemon=True).start()
    print(f"ETHII explorer indexer on http://{LISTEN[0]}:{LISTEN[1]}", flush=True)
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()


if __name__ == "__main__":
    main()
