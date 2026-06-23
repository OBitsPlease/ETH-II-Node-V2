#!/bin/bash
# ============================================================================
# ETH II MULTIPOOL CUTOVER (EU truth + tenants) -- PHASED, REVERSIBLE
# Goal: each pool's own address lands on the blocks it finds (on-chain reward
#       separation), no lag, no fork.
#
# WHY PHASED: the old single-shot version RESTARTED the archive tenants, which
# take minutes to stop; the v2 driver then armed them mid-reboot -> engine API
# "connection refused" -> no work -> chain paused. This version NEVER restarts a
# tenant. Tenants are armed LIVE via RPC (proven). Only truth is ever restarted,
# and only in Phase B, AFTER the tenants are already producing.
#
# SEQUENCE (run with a human watching balances between phases):
#   Phase A (EU, reward-neutral, reversible):
#       bash multipool-cutover.sh --phase A --confirm GO
#     -> verify ETH71 binary, backup, ARM=1 all tenants, fc-driver v1->v2
#        (NO tenant restart), confirm every gate serves fresh own-coinbase work
#        while truth still produces & still pays owner. Nothing reroutes yet.
#   Companion (US): bash /root/us-stratum-repoint.sh --confirm GO
#     -> owner pool now mines its own tenant gate :8550 (still pays owner ==
#        reward-neutral). WATCH: owner-tenant seals a block & it gossips to truth.
#   Phase B (EU, the actual switch):
#       bash multipool-cutover.sh --phase B --confirm GO
#     -> remove truth feeRecipient + drop ethash,miner from truth RPC, restart
#        ONLY truth. Truth becomes aggregator/relay; tenants are sole producers;
#        each pool's blocks pay its own wallet. New producers were already live
#        BEFORE the old one stopped -> no chain pause.
#
# Rollback at any time:  bash /root/multipool-rollback.sh --confirm GO
#                        (US) bash /root/us-stratum-rollback.sh --confirm GO
# ============================================================================
set +f
shopt -s nullglob
GENHASH="0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2"
TS=$(date -u +%Y%m%d-%H%M%S)
BK=/root/MULTIPOOL-CUTOVER-BACKUP-$TS
UNIT=/etc/systemd/system/ethii-node.service
FEEFLAG="--miner.pending.feeRecipient 0xbAA2144072f96b162017D47efdA18159Cba566e9"
ETH71BIN=/root/ethii-eth71
LIVEBIN=/root/ethii
J(){ curl -s -m8 -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' --data "$1"; }
GW(){ curl -s -m6 -X POST "http://127.0.0.1:$1" -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"ethash_getWork","params":[],"id":1}'; }

PHASE=""; CONFIRM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2;;
    --confirm) [ "$2" = "GO" ] && CONFIRM=1; shift 2;;
    *) shift;;
  esac
done

echo "=============================================="
echo " MULTIPOOL CUTOVER  $TS  phase=$PHASE confirm=$CONFIRM"
echo "=============================================="

# ---- chain identity guard (always) ----
B0=$(J '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' | grep -oE '"hash":"0x[0-9a-f]+"' | head -1)
HEAD0=$(J '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -oE '0x[0-9a-f]+' | head -1)
echo "PRE  block-0: $B0"
echo "PRE  head   : $HEAD0"
if ! echo "$B0" | grep -qi "${GENHASH#0x}"; then
  echo "!! ABORT: block-0 hash does NOT match canonical genesis. Nothing changed."
  exit 1
fi
echo "Chain identity OK."

if [ "$PHASE" != "A" ] && [ "$PHASE" != "B" ]; then
  echo "Usage: bash $0 --phase A|B --confirm GO"
  exit 0
fi

# ============================================================================
# PHASE A -- reward-neutral prep (no tenant restart, truth untouched)
# ============================================================================
if [ "$PHASE" = "A" ]; then
  echo "PLAN A:"
  echo "  1. Backup node unit + tenant confs + live binary -> $BK"
  echo "  2. Ensure ETH71 P2P binary is live (already deployed; verify only)."
  echo "  3. ARM=1 on every tenant conf."
  echo "  4. fc-driver v1 -> v2 (arms tenants via RPC; NO tenant restart)."
  echo "  5. Verify every gate serves fresh head+1 work; truth still pays owner."
  if [ "$CONFIRM" != "1" ]; then
    echo "----------------------------------------------"
    echo "DRY-RUN ONLY. To execute:  bash $0 --phase A --confirm GO"
    exit 0
  fi

  mkdir -p "$BK"
  cp -a "$UNIT" "$BK/ethii-node.service"
  cp -a /opt/ethii-tenants "$BK/ethii-tenants"
  cp -a "$LIVEBIN" "$BK/ethii.binary.bak"
  echo "$B0" > "$BK/PRE-BLOCK0.txt"; echo "$HEAD0" > "$BK/PRE-HEAD.txt"
  echo "Backed up -> $BK"

  # ETH71 binary should already be live. Deploy only if the live binary differs.
  if [ -f "$ETH71BIN" ] && ! cmp -s "$ETH71BIN" "$LIVEBIN"; then
    cp -a "$ETH71BIN" "/root/ethii.new.$$"; mv -f "/root/ethii.new.$$" "$LIVEBIN"
    echo "ETH71 binary deployed (atomic mv; takes effect on next truth restart)."
  else
    echo "ETH71 binary already live (no redeploy needed)."
  fi

  for f in /opt/ethii-tenants/0x*.conf; do
    if grep -q '^ARM=' "$f"; then sed -i 's/^ARM=.*/ARM=1/' "$f"; else printf '\nARM=1\n' >> "$f"; fi
    echo "  ARM=1 -> $(basename "$f")"
  done

  if systemctl is-active --quiet ethii-fc-driver.service; then
    systemctl disable --now ethii-fc-driver.service 2>/dev/null
  fi
  systemctl enable --now ethii-fc-driver-v2.service 2>/dev/null
  echo "fc-driver: v1 stopped, v2 active (arms tenants over RPC, no restart)."

  echo "--- waiting 20s for v2 to arm all tenants ---"; sleep 20
  echo "--- gate work check (each must return a 4-element work array) ---"
  for f in /opt/ethii-tenants/0x*.conf; do
    p=$(grep -oE '^RPC_PORT=[0-9]+' "$f" | cut -d= -f2)
    w=$(GW "$p" | grep -oE '"0x[0-9a-f]{64}"' | head -1)
    echo "  gate $p work=$w  ($(basename "$f"))"
  done
  echo "--- truth latest block miner (MUST still be owner 0xbaa2...) ---"
  J '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' | grep -oE '"miner":"0x[0-9a-f]+"'
  echo "=============================================="
  echo "PHASE A done (reward-neutral). NEXT, on US:"
  echo "    bash /root/us-stratum-repoint.sh --confirm GO"
  echo "Watch a few blocks: owner-tenant should seal & gossip; blocks still pay owner."
  echo "When satisfied, run Phase B:  bash $0 --phase B --confirm GO"
  echo "Rollback EU: bash /root/multipool-rollback.sh --confirm GO   Backup: $BK"
  exit 0
fi

# ============================================================================
# PHASE B -- the switch (stop truth producing; restart ONLY truth)
# ============================================================================
if [ "$PHASE" = "B" ]; then
  echo "PLAN B:"
  echo "  1. Pre-flight: confirm tenants armed & serving fresh work."
  echo "  2. Remove truth feeRecipient + drop ethash,miner from truth RPC API."
  echo "  3. Restart ONLY truth (tenants untouched)."
  echo "  4. Verify block-0 unchanged, head advancing (tenant-driven), truth refuses work."

  # pre-flight: at least one gate must be serving fresh work, else abort
  ARMED_OK=0
  for f in /opt/ethii-tenants/0x*.conf; do
    grep -q '^ARM=1' "$f" || continue
    p=$(grep -oE '^RPC_PORT=[0-9]+' "$f" | cut -d= -f2)
    GW "$p" | grep -qE '"0x[0-9a-f]{64}"' && { ARMED_OK=1; echo "  pre-flight OK: gate $p serving work"; }
  done
  if [ "$ARMED_OK" != "1" ]; then
    echo "!! ABORT: no armed tenant is serving fresh work. Run Phase A first / check tenants."
    exit 1
  fi

  if [ "$CONFIRM" != "1" ]; then
    echo "----------------------------------------------"
    echo "DRY-RUN ONLY. To execute:  bash $0 --phase B --confirm GO"
    exit 0
  fi

  mkdir -p "$BK"; cp -a "$UNIT" "$BK/ethii-node.service.preB"
  sed -i "s| $FEEFLAG||g" "$UNIT"
  sed -i "s|--http.api eth,net,web3,admin,debug,ethash,miner|--http.api eth,net,web3,admin,debug|g" "$UNIT"
  echo "Removed truth feeRecipient + dropped ethash,miner from truth RPC API."

  systemctl daemon-reload
  systemctl restart ethii-node.service
  echo "Restarted ONLY truth. Waiting 30s for it to rejoin as aggregator..."
  sleep 30

  B0b=$(J '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' | grep -oE '"hash":"0x[0-9a-f]+"' | head -1)
  H1=$(J '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -oE '0x[0-9a-f]+' | head -1)
  sleep 12
  H2=$(J '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -oE '0x[0-9a-f]+' | head -1)
  echo "POST block-0: $B0b   (MUST equal $B0)"
  echo "POST head   : $H1 -> $H2   (should advance = tenants producing)"
  echo "--- truth should now REFUSE work ---"
  GW 8545 | head -c 200; echo
  echo "--- peer eth versions (tenants on 71) ---"
  J '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' | grep -oE '"version":[0-9]+' | sort | uniq -c
  echo "=============================================="
  if [ "$B0b" = "$B0" ] && [ "$H2" != "$H1" ]; then
    echo "RESULT: identity preserved AND chain advancing under tenant production."
    echo "Verify each new block's miner field matches the finding pool's wallet."
  elif [ "$B0b" != "$B0" ]; then
    echo "!! BLOCK-0 CHANGED -> ROLLBACK NOW: bash /root/multipool-rollback.sh --confirm GO"
  else
    echo "!! HEAD NOT ADVANCING (no tenant production?) -> consider rollback:"
    echo "   bash /root/multipool-rollback.sh --confirm GO"
  fi
  echo "Backup dir: $BK"
  echo "=============================================="
  exit 0
fi
