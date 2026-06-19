#!/usr/bin/env python3
"""ETHII public RPC guard.

Sits between nginx /rpc and the local node (127.0.0.1:8545). Forwards only
whitelisted read-only JSON-RPC methods plus eth_sendRawTransaction; blocks
admin/debug/miner/txpool and anything else. Handles single and batch requests.
"""
import json
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NODE_URL = "http://127.0.0.1:8545"
LISTEN = ("127.0.0.1", 8093)
MAX_BODY = 256 * 1024

ALLOWED = {
    "web3_clientVersion", "web3_sha3",
    "net_version", "net_listening", "net_peerCount",
    "eth_chainId", "eth_blockNumber", "eth_syncing", "eth_protocolVersion",
    "eth_gasPrice", "eth_feeHistory", "eth_maxPriorityFeePerGas",
    "eth_getBalance", "eth_getStorageAt", "eth_getCode", "eth_getProof",
    "eth_getTransactionCount", "eth_call", "eth_estimateGas",
    "eth_sendRawTransaction",
    "eth_getBlockByNumber", "eth_getBlockByHash",
    "eth_getBlockTransactionCountByNumber", "eth_getBlockTransactionCountByHash",
    "eth_getTransactionByHash", "eth_getTransactionReceipt",
    "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionByBlockHashAndIndex",
    "eth_getUncleByBlockNumberAndIndex", "eth_getUncleByBlockHashAndIndex",
    "eth_getUncleCountByBlockNumber", "eth_getUncleCountByBlockHash",
    "eth_getLogs", "eth_mining", "eth_hashrate",
}


def denied(req_id):
    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": -32601, "message": "method not allowed on public RPC"}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._reply(405, {"error": "POST JSON-RPC only"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._reply(400, {"error": "bad request size"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except Exception:
            self._reply(400, {"error": "invalid JSON"})
            return

        batch = isinstance(payload, list)
        reqs = payload if batch else [payload]
        if len(reqs) > 50:
            self._reply(400, {"error": "batch too large"})
            return

        results = {}
        forward = []
        for i, r in enumerate(reqs):
            method = r.get("method") if isinstance(r, dict) else None
            if not isinstance(method, str) or method not in ALLOWED:
                results[i] = denied(r.get("id") if isinstance(r, dict) else None)
            else:
                forward.append((i, r))

        if forward:
            body = json.dumps([r for _, r in forward] if batch else forward[0][1]).encode()
            req = urllib.request.Request(NODE_URL, data=body,
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    node_out = json.loads(resp.read())
            except Exception:
                self._reply(502, {"error": "node unavailable"})
                return
            if batch:
                node_list = node_out if isinstance(node_out, list) else [node_out]
                for (i, _), out in zip(forward, node_list):
                    results[i] = out
            else:
                results[forward[0][0]] = node_out

        out = [results[i] for i in range(len(reqs))]
        self._reply(200, out if batch else out[0])


def main():
    print(f"ETHII RPC guard on http://{LISTEN[0]}:{LISTEN[1]} -> {NODE_URL}", flush=True)
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()


if __name__ == "__main__":
    main()
