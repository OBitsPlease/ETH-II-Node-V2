#!/usr/bin/env bash
# ETHII pool one-shot installer for Linux (amd64).
#
# Usage:
#   sudo bash setup-ethii-pool.sh ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX
#
# Installs an ETHII node + stratum pool under /opt/ethii, generates a pool
# wallet, sets up systemd services with auto-restart and a health guard,
# verifies the genesis hash, and starts everything.
set -euo pipefail

DL_BASE="https://www.ethii.net/dl"
GENESIS_URL="https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/genesis.json"
GENESIS_HASH="0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2"
NETWORK_ID=20482
INSTALL_DIR="/opt/ethii"
BOOTNODES="enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303,enode://348b5a90336ebd6be5f2910910c6870cadb8a6853820211f6a8696cb1446203a8a4fd54c9fcef39b63505bab43b8b3bd3528eb3dccdf4b62274ac191ad1e0ea0@91.99.231.217:30303"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

KEY="${1:-}"
[ -n "$KEY" ] || err "usage: sudo bash $0 <ETHII-download-key>"
[ "$(id -u)" = "0" ] || err "run as root (sudo)"
[ "$(uname -s)" = "Linux" ] || err "Linux only"
[ "$(uname -m)" = "x86_64" ] || err "amd64/x86_64 only"
command -v curl >/dev/null || err "curl is required (apt install curl)"
command -v systemctl >/dev/null || err "systemd is required"

if [ -f "$INSTALL_DIR/data/geth/chaindata/CURRENT" ] 2>/dev/null || systemctl is-active --quiet ethii-node 2>/dev/null; then
  err "existing ETHII install detected. To reinstall: systemctl stop ethii-stratum ethii-node; back up $INSTALL_DIR (especially pool-keystore.json + pool-password.txt) and remove it first."
fi

mkdir -p "$INSTALL_DIR"

info "Downloading ETHII node binary..."
curl -fsSL -o "$INSTALL_DIR/ethii" "$DL_BASE/ethii-linux-amd64?key=$KEY" \
  || err "node download failed — check your download key"
info "Downloading ETHII stratum binary..."
curl -fsSL -o "$INSTALL_DIR/stratum" "$DL_BASE/stratum-linux-amd64?key=$KEY" \
  || err "stratum download failed — check your download key"
chmod +x "$INSTALL_DIR/ethii" "$INSTALL_DIR/stratum"

info "Downloading genesis.json..."
curl -fsSL -o "$INSTALL_DIR/genesis.json" "$GENESIS_URL" || err "genesis download failed"
grep -q '"chainId": *20482' "$INSTALL_DIR/genesis.json" || err "genesis.json sanity check failed (chainId 20482 not found)"

info "Initializing chain database..."
"$INSTALL_DIR/ethii" --datadir "$INSTALL_DIR/data" --state.scheme hash init "$INSTALL_DIR/genesis.json"

info "Generating pool wallet..."
"$INSTALL_DIR/stratum" -init-wallet \
  -keystore "$INSTALL_DIR/pool-keystore.json" \
  -passfile "$INSTALL_DIR/pool-password.txt"
POOL_ADDR="$(python3 -c "import json;print('0x'+json.load(open('$INSTALL_DIR/pool-keystore.json'))['address'])" 2>/dev/null)" \
  || POOL_ADDR="0x$(grep -o '"address":"[0-9a-fA-F]*"' "$INSTALL_DIR/pool-keystore.json" | cut -d'"' -f4)"
[ -n "$POOL_ADDR" ] && [ "$POOL_ADDR" != "0x" ] || err "could not read pool wallet address"
info "Pool wallet: $POOL_ADDR"

info "Writing default payout config (PPLNS, 0.1 ETHII minimum)..."
cat > "$INSTALL_DIR/payout.json" <<EOF
{"miningAddress":"","minPayment":0.1,"mode":"pplns","pplnsWindow":1200}
EOF

info "Installing systemd services..."
cat > /usr/local/bin/ethii-miner-start.sh <<'EOF'
#!/usr/bin/env bash
# Arm remote work serving (no CPU mining) after node start. The stratum
# also re-arms every 60s; this just shortens the window after a node restart.
for i in $(seq 1 30); do
  sleep 2
  if curl -s -m 3 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"miner_start","params":[-1],"id":1}' \
    http://127.0.0.1:8545 | grep -q '"jsonrpc"'; then
    exit 0
  fi
done
exit 0
EOF
chmod +x /usr/local/bin/ethii-miner-start.sh

cat > /etc/systemd/system/ethii-node.service <<EOF
[Unit]
Description=ETHII Node
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=$INSTALL_DIR/ethii --datadir $INSTALL_DIR/data --networkid $NETWORK_ID --syncmode full --snapshot=false --state.scheme hash --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3,miner --miner.pending.feeRecipient $POOL_ADDR --bootnodes $BOOTNODES --maxpeers 50
ExecStartPost=/usr/local/bin/ethii-miner-start.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ethii-stratum.service <<EOF
[Unit]
Description=ETHII Stratum Pool
After=ethii-node.service
Wants=ethii-node.service

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/stratum -node http://127.0.0.1:8545 -stratum 0.0.0.0:3333 -a10-stratum 0.0.0.0:3336 -lowdiff-stratum 0.0.0.0:3334 -etherbase $POOL_ADDR -settings $INSTALL_DIR -keystore $INSTALL_DIR/pool-keystore.json -passfile $INSTALL_DIR/pool-password.txt -dashboard 0.0.0.0:8082
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

info "Installing health guard (restarts hung services)..."
cat > /usr/local/bin/ethii-health-guard.sh <<'EOF'
#!/usr/bin/env bash
# Restart services that are running but unresponsive. Crash recovery is
# handled by systemd Restart=always; this catches hangs.
RPC='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
if ! curl -s -m 10 -X POST -H "Content-Type: application/json" --data "$RPC" \
    http://127.0.0.1:8545 | grep -q '"result"'; then
  logger -t ethii-guard "node RPC unresponsive — restarting ethii-node"
  systemctl restart ethii-node
  exit 0
fi
if ! timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3333' 2>/dev/null; then
  logger -t ethii-guard "stratum port 3333 unresponsive — restarting ethii-stratum"
  systemctl restart ethii-stratum
fi
exec 3>&- 2>/dev/null || true
EOF
chmod +x /usr/local/bin/ethii-health-guard.sh

cat > /etc/systemd/system/ethii-health-guard.service <<EOF
[Unit]
Description=ETHII health guard check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ethii-health-guard.sh
EOF

cat > /etc/systemd/system/ethii-health-guard.timer <<EOF
[Unit]
Description=Run ETHII health guard every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

info "Starting services..."
systemctl daemon-reload
systemctl enable --now ethii-node
systemctl enable --now ethii-stratum
systemctl enable --now ethii-health-guard.timer

info "Waiting for node RPC..."
GEN=""
for i in $(seq 1 30); do
  sleep 2
  GEN="$(curl -s -m 3 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
    http://127.0.0.1:8545 | grep -o '"hash":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)" || true
  [ -n "$GEN" ] && break
done
[ -n "$GEN" ] || err "node did not come up — check: journalctl -u ethii-node -n 50"
if [ "$GEN" != "$GENESIS_HASH" ]; then
  systemctl stop ethii-stratum ethii-node
  err "GENESIS MISMATCH: got $GEN, expected $GENESIS_HASH. Wrong chain — services stopped."
fi
info "Genesis hash verified: $GEN"

echo
echo "============================================================"
echo " ETHII pool installed and running."
echo "============================================================"
echo " Pool wallet     : $POOL_ADDR"
echo "   Keystore      : $INSTALL_DIR/pool-keystore.json"
echo "   Password file : $INSTALL_DIR/pool-password.txt"
echo "   >>> BACK UP BOTH FILES NOW. They control all pool funds. <<<"
echo
echo " Miner ports     : 3333 (standard), 3334 (low difficulty), 3336 (A10 ASIC)"
echo " Dashboard       : http://<this-server-ip>:8082"
echo " P2P port        : 30303 (open TCP+UDP in your firewall for peering)"
echo
echo " Status   : systemctl status ethii-node ethii-stratum"
echo " Logs     : journalctl -u ethii-stratum -f"
echo " Payouts run automatically (PPLNS, 0.1 ETHII minimum)."
echo "============================================================"
