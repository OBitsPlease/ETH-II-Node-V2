#!/usr/bin/env bash
# ETHII peer-only one-shot installer for Linux (amd64).
#
# Usage:
#   sudo bash setup-ethii-peer.sh ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX

set -euo pipefail

DL_BASE="https://www.ethii.net/dl"
GENESIS_URL="https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/genesis.json"
PEER_SEEDS_URL="https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/peer-seeds.txt"
INSTALL_DIR="/opt/ethii-peer"
NETWORK_ID=20482
DEFAULT_BOOTNODES="enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303,enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"

err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

KEY="${1:-}"
[ -n "$KEY" ] || err "usage: sudo bash $0 <ETHII-download-key>"
[ "$(id -u)" = "0" ] || err "run as root (sudo)"
[ "$(uname -s)" = "Linux" ] || err "Linux only"
[ "$(uname -m)" = "x86_64" ] || err "amd64/x86_64 only"
command -v curl >/dev/null || err "curl is required (apt install curl)"
command -v systemctl >/dev/null || err "systemd is required"

info "Pre-flight safety checks..."
if systemctl is-active --quiet ethii-relay-node 2>/dev/null || [[ -d "$INSTALL_DIR/data/geth/chaindata" ]]; then
  err "existing ETHII peer install detected. To reinstall: systemctl stop ethii-relay-node; back up $INSTALL_DIR and remove it first."
fi
if [[ -f /etc/systemd/system/ethii-relay-node.service ]]; then
  err "found existing /etc/systemd/system/ethii-relay-node.service. Remove or back up old install first."
fi

echo "============================================================"
echo " ETHII Peer Node Configuration"
echo "============================================================"
read -p "Which P2P port should your node listen on? (Press enter for default 30303): " P2P_PORT < /dev/tty
P2P_PORT=${P2P_PORT:-30303}
read -p "Which local RPC port should your node use? (Press enter for default 8545): " RPC_PORT < /dev/tty
RPC_PORT=${RPC_PORT:-8545}
read -p "Maximum peer connections? (Press enter for default 50): " MAX_PEERS < /dev/tty
MAX_PEERS=${MAX_PEERS:-50}

for p in "$P2P_PORT" "$RPC_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] || err "invalid port: $p"
done
[[ "$MAX_PEERS" =~ ^[0-9]+$ ]] || err "invalid max peers: $MAX_PEERS"

BUSY=""
for p in "$P2P_PORT" "$RPC_PORT"; do
  if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$p$"; then
    BUSY="$BUSY $p"
  fi
done
if [[ -n "$BUSY" ]]; then
  err "port(s)$BUSY already in use on this server. Free those ports and retry."
fi

mkdir -p "$INSTALL_DIR/data"

info "Downloading ETHII node binary..."
curl -fsSL -o "$INSTALL_DIR/ethii" "$DL_BASE/ethii-linux-amd64?key=$KEY" \
  || err "node download failed — check your download key"
chmod +x "$INSTALL_DIR/ethii"

info "Downloading genesis.json..."
curl -fsSL -o "$INSTALL_DIR/genesis.json" "$GENESIS_URL" || err "genesis download failed"
grep -q '"chainId": *20482' "$INSTALL_DIR/genesis.json" || err "genesis sanity check failed (chainId 20482 not found)"

info "Preparing trusted peer seed list..."
SEEDS_FILE="$INSTALL_DIR/peer-seeds.txt"
if ! curl -fsSL -o "$SEEDS_FILE" "$PEER_SEEDS_URL"; then
  printf '%s\n' "${DEFAULT_BOOTNODES//,/\\n}" > "$SEEDS_FILE"
fi
mapfile -t SEEDS < <(grep -E '^enode://' "$SEEDS_FILE" | sed 's/[[:space:]]*$//' | awk '!seen[$0]++')
if [[ "${#SEEDS[@]}" -eq 0 ]]; then
  mapfile -t SEEDS < <(printf '%s\n' "${DEFAULT_BOOTNODES//,/\\n}")
fi
BOOTNODES_CSV="$(IFS=,; echo "${SEEDS[*]}")"
P2P_CONFIG="$INSTALL_DIR/p2p-config.toml"
{
  echo "[Node.P2P]"
  echo "NoDiscovery = false"
  echo "DiscoveryV4 = true"
  echo "DiscoveryV5 = true"
  echo "MaxPeers = $MAX_PEERS"
  printf "StaticNodes = ["
  for i in "${!SEEDS[@]}"; do
    [[ $i -gt 0 ]] && printf ", "
    printf "\"%s\"" "${SEEDS[$i]}"
  done
  echo "]"
  printf "TrustedNodes = ["
  for i in "${!SEEDS[@]}"; do
    [[ $i -gt 0 ]] && printf ", "
    printf "\"%s\"" "${SEEDS[$i]}"
  done
  echo "]"
} > "$P2P_CONFIG"

info "Registering peer with EU Truth Node firewall..."
PEER_RES="$(curl -fsSL "http://91.99.231.217/dl/peer-provision?key=$KEY&p2p_port=$P2P_PORT" || true)"
if ! echo "$PEER_RES" | grep -q '"status":"ok"\|"status": "ok"'; then
  err "failed to register peer on EU server: $PEER_RES"
fi
info "EU registration successful: $PEER_RES"

info "Initializing chain database..."
"$INSTALL_DIR/ethii" --datadir "$INSTALL_DIR/data" --state.scheme hash init "$INSTALL_DIR/genesis.json" >/dev/null

EXTERNAL_IP="$(curl -sf --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$EXTERNAL_IP" ]]; then
  NAT_FLAG="--nat any"
else
  NAT_FLAG="--nat extip:$EXTERNAL_IP"
fi

info "Installing systemd service..."
cat > /etc/systemd/system/ethii-relay-node.service <<EOF
[Unit]
Description=ETHII Relay Node (Peer-Only, Non-Mining)
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=$INSTALL_DIR/ethii --config $P2P_CONFIG --datadir $INSTALL_DIR/data --networkid $NETWORK_ID --syncmode full --snapshot=false --gcmode archive --state.scheme hash --http --http.addr 127.0.0.1 --http.port $RPC_PORT --http.corsdomain * --http.vhosts * --http.api eth,net,web3,admin,debug,ethash --port $P2P_PORT --bootnodes $BOOTNODES_CSV --maxpeers $MAX_PEERS $NAT_FLAG
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1; then
  info "Opening UFW for peer port..."
  ufw allow "$P2P_PORT/tcp" >/dev/null 2>&1 || true
  ufw allow "$P2P_PORT/udp" >/dev/null 2>&1 || true
fi

info "Starting relay node..."
systemctl daemon-reload
systemctl enable --now ethii-relay-node

sleep 2
if ! systemctl is-active --quiet ethii-relay-node; then
  err "ethii-relay-node failed to start. Check: journalctl -u ethii-relay-node -n 80 --no-pager"
fi

echo
echo "============================================================"
echo " ETHII peer node installed and running."
echo "============================================================"
echo " P2P port        : $P2P_PORT (open TCP+UDP in OS/cloud firewall)"
echo " Local RPC       : 127.0.0.1:$RPC_PORT"
echo " Max peers       : $MAX_PEERS"
echo " EU registration : completed"
echo
echo " Status          : systemctl status ethii-relay-node"
echo " Logs            : journalctl -u ethii-relay-node -f"
echo "============================================================"
