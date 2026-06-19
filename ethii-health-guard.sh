#!/usr/bin/env bash
set -euo pipefail

ROLE="${ETHII_ROLE:-node}"
STATE_DIR="/var/lib/ethii-health"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"

rpc_call() {
  local method="$1"
  local payload
  payload=$(printf '{"jsonrpc":"2.0","method":"%s","params":[],"id":1}' "$method")
  curl -sS --max-time 4 -H 'Content-Type: application/json' --data "$payload" http://127.0.0.1:8545 || return 1
}

hex_to_dec() {
  local h="$1"
  printf '%d' "$((16#${h#0x}))"
}

log() {
  logger -t ethii-health-guard "$*"
  echo "$(date -Is) $*"
}

if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<STATE
LAST_BLOCK=0
STAGNANT_COUNT=0
FAIL_COUNT=0
HEALTHY_COUNT=0
LAST_ACTION_EPOCH=0
STATE
fi

# shellcheck disable=SC1090
source "$STATE_FILE"
HEALTHY_COUNT=${HEALTHY_COUNT:-0}

now=$(date +%s)
unhealthy=0
restart_eligible=0

peer_resp=$(rpc_call net_peerCount || true)
block_resp=$(rpc_call eth_blockNumber || true)

peer_hex=$(echo "$peer_resp" | grep -oE '"result":"0x[0-9a-fA-F]+"' | head -1 | cut -d'"' -f4 || true)
block_hex=$(echo "$block_resp" | grep -oE '"result":"0x[0-9a-fA-F]+"' | head -1 | cut -d'"' -f4 || true)

if [[ -z "$peer_hex" || -z "$block_hex" ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  HEALTHY_COUNT=0
  unhealthy=1
  log "rpc failure detected fail_count=$FAIL_COUNT role=$ROLE"
else
  FAIL_COUNT=0
  block_dec=$(hex_to_dec "$block_hex")
  peer_dec=$(hex_to_dec "$peer_hex")
  if [[ "$block_dec" -le "$LAST_BLOCK" ]]; then
    STAGNANT_COUNT=$((STAGNANT_COUNT + 1))
  else
    STAGNANT_COUNT=0
    LAST_BLOCK=$block_dec
  fi
  if [[ "$peer_dec" -lt 1 || "$STAGNANT_COUNT" -ge 6 ]]; then
    unhealthy=1
    HEALTHY_COUNT=0
    log "degraded node state peers=$peer_dec block=$block_dec stagnant_count=$STAGNANT_COUNT role=$ROLE"
  else
    HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
  fi
fi

if [[ "$FAIL_COUNT" -ge 3 || "$STAGNANT_COUNT" -ge 10 ]]; then
  restart_eligible=1
fi

if [[ "$unhealthy" -eq 1 ]]; then
  if [[ "$FAIL_COUNT" -ge 2 || "$STAGNANT_COUNT" -ge 6 ]]; then
    if systemctl list-unit-files | grep -q '^ethii-stratum'; then
      if systemctl is-active --quiet ethii-stratum; then
        systemctl stop ethii-stratum || true
        log "stratum paused due to unhealthy node"
      fi
    fi
  fi

  if [[ "$restart_eligible" -eq 1 && $(( now - LAST_ACTION_EPOCH )) -ge 900 ]]; then
    systemctl restart ethii-node --no-block || true
    LAST_ACTION_EPOCH=$now
    log "ethii-node restart requested by health guard"
  fi
else
  # Restart stratum whenever the node is healthy and the service exists,
  # regardless of role — ETHII_ROLE=node is the default but pool VPS nodes
  # also need the stratum to come back automatically after a health trip.
  if [[ "$HEALTHY_COUNT" -ge 2 ]] && systemctl list-unit-files | grep -q '^ethii-stratum'; then
    if ! systemctl is-active --quiet ethii-stratum; then
      systemctl start ethii-stratum || true
      log "stratum resumed after healthy node checks"
    fi
  fi
fi

cat > "$STATE_FILE" <<STATE
LAST_BLOCK=$LAST_BLOCK
STAGNANT_COUNT=$STAGNANT_COUNT
FAIL_COUNT=$FAIL_COUNT
HEALTHY_COUNT=$HEALTHY_COUNT
LAST_ACTION_EPOCH=$LAST_ACTION_EPOCH
STATE
