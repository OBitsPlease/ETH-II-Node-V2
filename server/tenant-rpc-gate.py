#!/usr/bin/env python3
import argparse
import json
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORK_METHODS = {"ethash_getWork", "ethash_submitWork", "eth_submitWork"}
TRUTH_METHODS = {
    "eth_chainId", "net_version", "net_peerCount", "eth_syncing",
    "eth_gasPrice", "eth_feeHistory", "eth_maxPriorityFeePerGas"
}


def rpc(url, method, params=None, timeout=2.5):
    if params is None:
        params = []
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def hx(v):
    if isinstance(v, str) and v.startswith("0x"):
        try:
            return int(v, 16)
        except Exception:
            return 0
    return 0


class Gate:
    def __init__(self, upstream, truth, lag_max):
        self.upstream = upstream
        self.truth = truth
        self.lag_max = lag_max

    def sanitize_request(self, reqj):
        method = reqj.get("method", "")
        if method == "miner_start":
            # External miners still submit via ethash_submitWork; do not allow local CPU mining threads.
            reqj["params"] = [0]
        return reqj

    def sync_status(self):
        t_hex = rpc(self.truth, "eth_blockNumber").get("result")
        u_hex = rpc(self.upstream, "eth_blockNumber").get("result")
        t_dec = hx(t_hex)
        u_dec = hx(u_hex)
        drift = abs(t_dec - u_dec)

        mismatch = False
        t_hash = None
        u_hash_at_t = None
        if t_dec > 0 and u_dec >= t_dec:
            blk = hex(t_dec)
            t_hash = (rpc(self.truth, "eth_getBlockByNumber", [blk, False]).get("result") or {}).get("hash")
            u_hash_at_t = (rpc(self.upstream, "eth_getBlockByNumber", [blk, False]).get("result") or {}).get("hash")
            mismatch = bool(t_hash and u_hash_at_t and t_hash != u_hash_at_t)

        return drift, t_dec, u_dec, mismatch, t_hash, u_hash_at_t

    def route(self, method):
        if method in TRUTH_METHODS:
            return self.truth
        return self.upstream


class Handler(BaseHTTPRequestHandler):
    gate = None

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        try:
            reqj = json.loads(raw.decode() or "{}")
        except Exception:
            return self.reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        if not isinstance(reqj, dict):
            return self.reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}})

        reqj = self.gate.sanitize_request(reqj)
        method = reqj.get("method", "")

        if method in {"miner_start", "miner_stop"}:
            return self.reply({"jsonrpc": "2.0", "id": reqj.get("id"), "error": {"code": -32013, "message": "miner methods disabled at gate; use ethash_getWork/ethash_submitWork"}})

        if method in WORK_METHODS:
            try:
                drift, t_dec, u_dec, mismatch, _, _ = self.gate.sync_status()
                if drift > self.gate.lag_max or mismatch:
                    try:
                        rpc(self.gate.upstream, "miner_stop", [])
                    except Exception:
                        pass
                    return self.reply(
                        {
                            "jsonrpc": "2.0",
                            "id": reqj.get("id"),
                            "error": {
                                "code": -32010,
                                "message": f"desynced drift={drift} truth={t_dec} upstream={u_dec} mismatch={str(mismatch).lower()}",
                            },
                        }
                    )
            except Exception as e:
                return self.reply(
                    {
                        "jsonrpc": "2.0",
                        "id": reqj.get("id"),
                        "error": {"code": -32011, "message": f"sync check failed: {e}"},
                    }
                )

        target = self.gate.route(method)
        try:
            fwd = json.dumps(reqj).encode()
            up = urllib.request.Request(target, data=fwd, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(up, timeout=8) as r:
                out = r.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        except Exception as e:
            self.reply(
                {
                    "jsonrpc": "2.0",
                    "id": reqj.get("id"),
                    "error": {"code": -32012, "message": f"upstream error: {e}"},
                }
            )

    def reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *args):
        return


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-port", type=int, required=True)
    ap.add_argument("--upstream-port", type=int, required=True)
    ap.add_argument("--truth-port", type=int, default=8545)
    ap.add_argument("--lag-max", type=int, default=1)
    args = ap.parse_args()

    Handler.gate = Gate(
        upstream=f"http://127.0.0.1:{args.upstream_port}",
        truth=f"http://127.0.0.1:{args.truth_port}",
        lag_max=args.lag_max,
    )
    ThreadingHTTPServer(("0.0.0.0", args.listen_port), Handler).serve_forever()
