#!/bin/bash
set -euo pipefail

WALLET="${1:-}"
IP="${2:-}"
PORTS="${3:-}"
KEY="${4:-}"

if [[ -z "$WALLET" || -z "$IP" ]]; then
    echo '{"error": "Missing args"}'
    exit 1
fi
if [[ ! "$WALLET" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo '{"error": "Invalid wallet"}'
    exit 1
fi

WALLET_LC="$(echo "$WALLET" | tr '[:upper:]' '[:lower:]')"
TENANTS_DIR="/opt/ethii-tenants"
mkdir -p "$TENANTS_DIR"

TENANT_CONF="$TENANTS_DIR/$WALLET_LC.conf"
LAST_PORT_FILE="$TENANTS_DIR/last_port"
SEEDS_FILE="/opt/ethii-downloads/peer-seeds.txt"
GATE_SCRIPT="/root/tenant-rpc-gate.py"
DEFAULT_SEEDS=(
    "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303"
    "enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"
)

ensure_firewall_rule() {
    local source_ip="$1"
    local rpc_port="$2"

    if [[ "$source_ip" == *:* ]]; then
        if ! nft list chain inet filter input | grep -Fq "ip6 saddr $source_ip tcp dport $rpc_port accept"; then
            nft add rule inet filter input ip6 saddr "$source_ip" tcp dport "$rpc_port" accept
        fi
    else
        if ! nft list chain inet filter input | grep -Fq "ip saddr $source_ip tcp dport $rpc_port accept"; then
            nft add rule inet filter input ip saddr "$source_ip" tcp dport "$rpc_port" accept
        fi
    fi
    nft list ruleset > /etc/nftables.conf
}

install_gate_script() {
    # Shared RPC gate used by ALL pool gates. Never clobber a newer/tuned
    # live copy; only install when missing so per-pool provisioning is safe.
    if [[ -f "$GATE_SCRIPT" ]]; then
        return 0
    fi
    cat > "$GATE_SCRIPT" <<'PY'
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
PY
    chmod +x "$GATE_SCRIPT"
}

install_gate_script

if [[ -f "$TENANT_CONF" ]]; then
    RPC_PORT="$(grep '^RPC_PORT=' "$TENANT_CONF" | cut -d= -f2 || true)"
    P2P_PORT="$(grep '^P2P_PORT=' "$TENANT_CONF" | cut -d= -f2 || true)"
    AUTHRPC_PORT="$(grep '^AUTHRPC_PORT=' "$TENANT_CONF" | cut -d= -f2 || true)"
    INTERNAL_RPC_PORT="$(grep '^INTERNAL_RPC_PORT=' "$TENANT_CONF" | cut -d= -f2 || true)"
    if [[ -z "$RPC_PORT" ]]; then
        echo '{"error": "Existing tenant conf missing RPC_PORT"}'
        exit 1
    fi
    if [[ -z "$P2P_PORT" ]]; then
        P2P_PORT=$((30304 + (RPC_PORT - 8546)))
    fi
    if [[ -z "$AUTHRPC_PORT" ]]; then
        AUTHRPC_PORT=$((9551 + (RPC_PORT - 8546)))
    fi
    if [[ -z "$INTERNAL_RPC_PORT" ]]; then
        INTERNAL_RPC_PORT=$((RPC_PORT + 10000))
        echo "INTERNAL_RPC_PORT=$INTERNAL_RPC_PORT" >> "$TENANT_CONF"
    fi
    # Ensure existing pools are armed so fc-driver-v2 routes their own-coinbase work.
    if ! grep -q '^ARM=' "$TENANT_CONF"; then
        echo "ARM=1" >> "$TENANT_CONF"
    fi
else
    # --- robust port allocation -------------------------------------------
    # Reserved truth ports must never be reused (8545 http, 8551 authrpc),
    # nor any port already claimed by another tenant conf or currently bound.
    RESERVED_PORTS="8545 8551"
    USED_RPC_PORTS="$(grep -h '^RPC_PORT=' "$TENANTS_DIR"/*.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ' || true)"
    port_bound() { ss -ltn 2>/dev/null | grep -qE "[:.]$1 " ; }
    rpc_free() {
        local p="$1" r
        for r in $RESERVED_PORTS $USED_RPC_PORTS; do [[ "$p" == "$r" ]] && return 1; done
        port_bound "$p" && return 1
        return 0
    }
    if [[ ! -f "$LAST_PORT_FILE" ]]; then
        echo "8546" > "$LAST_PORT_FILE"
    fi
    CAND="$(cat "$LAST_PORT_FILE")"
    [[ "$CAND" =~ ^[0-9]+$ ]] || CAND=8546
    # advance until RPC port and all derived ports are free
    while : ; do
        rpc_free "$CAND" || { CAND=$((CAND+1)); continue; }
        RPC_PORT="$CAND"
        P2P_PORT=$((30304 + (RPC_PORT - 8546)))
        AUTHRPC_PORT=$((9551 + (RPC_PORT - 8546)))
        INTERNAL_RPC_PORT=$((RPC_PORT + 10000))
        if port_bound "$P2P_PORT" || port_bound "$AUTHRPC_PORT" || port_bound "$INTERNAL_RPC_PORT"; then
            CAND=$((CAND+1)); continue
        fi
        break
    done
    echo "$((RPC_PORT + 1))" > "$LAST_PORT_FILE"

    echo "RPC_PORT=$RPC_PORT" > "$TENANT_CONF"
    echo "INTERNAL_RPC_PORT=$INTERNAL_RPC_PORT" >> "$TENANT_CONF"
    echo "P2P_PORT=$P2P_PORT" >> "$TENANT_CONF"
    echo "AUTHRPC_PORT=$AUTHRPC_PORT" >> "$TENANT_CONF"
    echo "IP=$IP" >> "$TENANT_CONF"
    echo "PORTS=$PORTS" >> "$TENANT_CONF"
    echo "KEY=$KEY" >> "$TENANT_CONF"
    # ARM=1 => fc-driver-v2 serves this pool fresh head+1 work paying its own
    # wallet (on-chain reward separation). Proven-safe; arming alone never seals.
    echo "ARM=1" >> "$TENANT_CONF"
fi

DATADIR="/root/ethii-tenant-data-$WALLET_LC"
mkdir -p "$DATADIR"
cp /root/ethii-data/genesis* "$DATADIR/" 2>/dev/null || true
if [[ ! -d "$DATADIR/geth/chaindata" ]]; then
    /root/ethii --datadir "$DATADIR" --state.scheme hash init /root/genesis.json >/dev/null 2>&1
fi

SEEDS=()
if [[ -f "$SEEDS_FILE" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [[ "$line" == enode://* ]] && SEEDS+=("$line")
    done < "$SEEDS_FILE"
fi
if [[ "${#SEEDS[@]}" -eq 0 ]]; then
    SEEDS=("${DEFAULT_SEEDS[@]}")
fi

BOOTNODES_CSV="$(IFS=,; echo "${SEEDS[*]}")"
TOML_LIST=""
for i in "${!SEEDS[@]}"; do
    [[ "$i" -gt 0 ]] && TOML_LIST+=", "
    TOML_LIST+="\"${SEEDS[$i]}\""
done

P2P_CONFIG="/root/ethii-tenant-config-$WALLET_LC.toml"
cat > "$P2P_CONFIG" <<CFG
[Node.P2P]
NoDiscovery = false
DiscoveryV4 = true
DiscoveryV5 = true
MaxPeers = 16
StaticNodes = [$TOML_LIST]
TrustedNodes = [$TOML_LIST]
CFG

SERVICE_FILE="/etc/systemd/system/ethii-tenant-$WALLET_LC.service"
cat <<SVC > "$SERVICE_FILE"
[Unit]
Description=ETHII Tenant Node ($WALLET_LC)
After=network.target

[Service]
User=root
Group=root
Type=simple
Restart=always
RestartSec=5
ExecStart=/root/ethii --config $P2P_CONFIG --datadir $DATADIR --networkid 20482 --syncmode full --gcmode full --snapshot=false --state.scheme hash --http --http.addr 127.0.0.1 --http.port $INTERNAL_RPC_PORT --http.corsdomain "*" --http.vhosts "*" --http.api eth,net,web3,admin,debug,ethash,miner --authrpc.port $AUTHRPC_PORT --miner.pending.feeRecipient $WALLET_LC --port $P2P_PORT --bootnodes "$BOOTNODES_CSV" --maxpeers 64 --cache 1024

[Install]
WantedBy=multi-user.target
SVC

GATE_SERVICE_FILE="/etc/systemd/system/ethii-gate-$RPC_PORT.service"
cat <<GSVC > "$GATE_SERVICE_FILE"
[Unit]
Description=ETHII RPC gate $RPC_PORT -> tenant $INTERNAL_RPC_PORT
After=network.target ethii-tenant-$WALLET_LC.service

[Service]
Type=simple
User=root
Group=root
Restart=always
RestartSec=2
ExecStart=/usr/bin/python3 $GATE_SCRIPT --listen-port $RPC_PORT --upstream-port $INTERNAL_RPC_PORT --truth-port 8545 --lag-max 32

[Install]
WantedBy=multi-user.target
GSVC

systemctl daemon-reload
systemctl enable "ethii-tenant-$WALLET_LC.service" >/dev/null 2>&1 || true
systemctl enable "ethii-gate-$RPC_PORT.service" >/dev/null 2>&1 || true
systemctl restart "ethii-tenant-$WALLET_LC.service"
systemctl restart "ethii-gate-$RPC_PORT.service"

ensure_firewall_rule "$IP" "$RPC_PORT"

echo "{\"status\": \"ok\", \"rpc_port\": $RPC_PORT, \"internal_rpc_port\": $INTERNAL_RPC_PORT, \"msg\": \"provisioned successfully\"}"
