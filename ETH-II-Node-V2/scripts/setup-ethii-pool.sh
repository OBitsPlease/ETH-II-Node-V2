#!/usr/bin/env bash
# ETHII pool one-shot installer for Linux (amd64).
#
# Usage:
#   sudo bash setup-ethii-pool.sh ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX
#
# Installs an ETHII stratum pool, generates a pool wallet, sets up
# systemd services with auto-restart, auto-provisions a Truth Node
# on the EU server, and starts everything.
set -euo pipefail

DL_BASE="https://www.ethii.net/dl"
INSTALL_DIR="/opt/ethii"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

KEY="${1:-}"
[ -n "$KEY" ] || err "usage: sudo bash $0 <ETHII-download-key>"
[ "$(id -u)" = "0" ] || err "run as root (sudo)"
[ "$(uname -s)" = "Linux" ] || err "Linux only"
[ "$(uname -m)" = "x86_64" ] || err "amd64/x86_64 only"
command -v curl >/dev/null || err "curl is required (apt install curl)"
command -v systemctl >/dev/null || err "systemd is required"

info "Pre-flight safety checks..."
if systemctl is-active --quiet ethii-stratum 2>/dev/null; then
  err "existing ETHII install detected. To reinstall: systemctl stop ethii-stratum; back up $INSTALL_DIR (especially pool-keystore.json + pool-password.txt) and remove it first."
fi

# Ask for Ports
echo "============================================================"
echo " ETHII Pool Port Configuration"
echo "============================================================"
read -p "Which port for Standard GPU/ASIC mining? (Press enter for default 3335): " PORT_STD
PORT_STD=${PORT_STD:-3335}
read -p "Which port for Low Diff mining? (Press enter for default 3334): " PORT_LOW
PORT_LOW=${PORT_LOW:-3334}
read -p "Which port for A10/A10 Pro mining? (Press enter for default 3336): " PORT_A10
PORT_A10=${PORT_A10:-3336}

BUSY=""
read -p "Which port for the web dashboard? (Press enter for default 8082): " PORT_DASH
PORT_DASH=${PORT_DASH:-8082}

for p in $PORT_STD $PORT_LOW $PORT_A10 $PORT_DASH; do
  if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$p\$"; then
    BUSY="$BUSY $p"
  fi
done
if [ -n "$BUSY" ]; then
  err "port(s)$BUSY already in use on this server. Nothing was installed. Free those ports or use a dedicated server."
fi

mkdir -p "$INSTALL_DIR"

info "Downloading ETHII stratum binary..."
curl -fsSL -o "$INSTALL_DIR/stratum" "$DL_BASE/stratum-linux-amd64?key=$KEY" \
  || err "stratum download failed  check your download key"
chmod +x "$INSTALL_DIR/stratum"

info "Generating pool wallet..."
"$INSTALL_DIR/stratum" -init-wallet \
  -keystore "$INSTALL_DIR/pool-keystore.json" \
  -passfile "$INSTALL_DIR/pool-password.txt"

POOL_ADDR="$(python3 -c "import json;print('0x'+json.load(open('$INSTALL_DIR/pool-keystore.json'))['address'])" 2>/dev/null)" \
  || POOL_ADDR="0x$(grep -o '"address":"[0-9a-fA-F]*"' "$INSTALL_DIR/pool-keystore.json" | cut -d'"' -f4)"
[ -n "$POOL_ADDR" ] && [ "$POOL_ADDR" != "0x" ] || err "could not read pool wallet address"

info "Pool wallet generated: $POOL_ADDR"
info "  Keystore: $INSTALL_DIR/pool-keystore.json"
info "  Password: $INSTALL_DIR/pool-password.txt"
info "    Back up these files immediately (SCP off-server)"

info "Auto-provisioning Truth Node on EU Server..."
PORTS="${PORT_STD},${PORT_LOW},${PORT_A10}"
PROVISION_RES=$(curl -s "http://91.99.231.217/dl/provision?key=$KEY&wallet=$POOL_ADDR&ports=$PORTS")

# Extract rpc_port using regex
RPC_PORT=$(echo "$PROVISION_RES" | grep -o '"rpc_port": *[0-9]*' | grep -o '[0-9]*' | head -1)

if [[ -z "$RPC_PORT" ]]; then
    err "Failed to provision node on Truth Server: $PROVISION_RES"
fi

info "Assigned Dedicated RPC Port on Truth Node: $RPC_PORT"

info "Writing default payout config (PPLNS, 0.1 ETHII minimum)..."
cat > "$INSTALL_DIR/payout.json" <<EOF
{"miningAddress":"$POOL_ADDR","minPayment":0.1,"mode":"pplns","pplnsWindow":1200}
EOF

info "Installing systemd services..."
cat > /etc/systemd/system/ethii-stratum.service <<EOF
[Unit]
Description=ETHII Stratum Pool
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/stratum -node http://91.99.231.217:$RPC_PORT -stratum 0.0.0.0:$PORT_STD -a10-stratum 0.0.0.0:$PORT_A10 -lowdiff-stratum 0.0.0.0:$PORT_LOW -etherbase $POOL_ADDR -settings $INSTALL_DIR -keystore $INSTALL_DIR/pool-keystore.json -passfile $INSTALL_DIR/pool-password.txt -dashboard 0.0.0.0:$PORT_DASH
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

info "Creating pool information files..."
cat > "$INSTALL_DIR/POOL-INFO.txt" <<EOF

  ETHII POOL OPERATOR INFO
═

Pool Wallet Address: $POOL_ADDR
  This address receives all block mining rewards.
  Miners are paid from this wallet based on their shares (PPLNS).

Keystore File: $INSTALL_DIR/pool-keystore.json
Password File: $INSTALL_DIR/pool-password.txt
    KEEP THESE SAFE - They control all pool funds!

Pool Connection:
  Standard Miners:        YOUR_IP:$PORT_STD
  Low-Difficulty:         YOUR_IP:$PORT_LOW
  Innosilicon A10 ASIC:   YOUR_IP:$PORT_A10
  Dashboard:              http://YOUR_IP:$PORT_DASH

Miner Connection Format:
  stratum+tcp://YOUR_IP:$PORT_STD
  username: MINER_WALLET_ADDRESS
  password: x

EOF

info "Starting services..."
systemctl daemon-reload
systemctl enable --now ethii-stratum

echo
echo "============================================================"
echo " ETHII pool installed and running."
echo "============================================================"
echo " Pool wallet     : $POOL_ADDR"
echo "   Keystore      : $INSTALL_DIR/pool-keystore.json"
echo "   Password file : $INSTALL_DIR/pool-password.txt"
echo "   >>> BACK UP BOTH FILES NOW. They control all pool funds. <<<"
echo
echo " Miner ports     : $PORT_STD (standard), $PORT_LOW (low difficulty), $PORT_A10 (A10 ASIC)"
echo " Dashboard       : http://<this-server-ip>:$PORT_DASH"
echo " Status          : systemctl status ethii-stratum"
echo " Logs            : journalctl -u ethii-stratum -f"
echo "============================================================"
