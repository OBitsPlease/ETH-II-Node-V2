#!/bin/bash
# ============================================================================
# ETH II MULTIPOOL ROLLBACK (EU) -- restores pre-cutover state from the most
# recent MULTIPOOL-CUTOVER-BACKUP-*. Reverses binary, truth unit, tenant ARM,
# and fc-driver. Run with --confirm GO.
# ============================================================================
set +f
shopt -s nullglob
GENHASH="0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2"
UNIT=/etc/systemd/system/ethii-node.service
TENANT_OWNER=ethii-tenant-0xbaa2144072f96b162017d47efda18159cba566e9.service
TENANT_VEXTA=ethii-tenant-0x5a5f5d4d3f1a72495d19f95a54a8728ba7e627ae.service
J(){ curl -s -m8 -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' --data "$1"; }

BK=$(ls -1d /root/MULTIPOOL-CUTOVER-BACKUP-* 2>/dev/null | sort | tail -1)
echo "ROLLBACK using backup: ${BK:-<none found>}"
if [ -z "$BK" ]; then echo "!! No cutover backup found. Aborting."; exit 1; fi

if [ "$1" != "--confirm" ] || [ "$2" != "GO" ]; then
  echo "DRY-RUN. Would restore binary, $UNIT, tenant confs, fc-driver from $BK."
  echo "To execute: bash $0 --confirm GO"; exit 0
fi

# restore binary (atomic; survives 'Text file busy') + unit + tenant confs
cp -a "$BK/ethii.binary.bak" "/root/ethii.new.$$"
mv -f "/root/ethii.new.$$" /root/ethii
cp -a "$BK/ethii-node.service" "$UNIT"
cp -a "$BK/ethii-tenants/." /opt/ethii-tenants/
rm -f "/opt/ethii-tenants/0x*.conf"
echo "Restored binary, truth unit, tenant confs."

# fc-driver v2 -> v1
systemctl disable --now ethii-fc-driver-v2.service 2>/dev/null
systemctl daemon-reload
systemctl enable --now ethii-fc-driver.service 2>/dev/null
echo "fc-driver restored v2 -> v1."

systemctl daemon-reload
systemctl restart ethii-node.service
systemctl restart "$TENANT_OWNER"
systemctl restart "$TENANT_VEXTA"
echo "Restarted truth + tenants. Waiting 30s..."
sleep 30
# re-arm truth work serving (legacy template) so owner pool on :8545 keeps working
J '{"jsonrpc":"2.0","method":"miner_start","params":[-1],"id":1}' >/dev/null 2>&1
B0=$(J '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' | grep -oE '"hash":"0x[0-9a-f]+"' | head -1)
HEAD=$(J '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -oE '0x[0-9a-f]+' | head -1)
echo "block-0: $B0"
echo "head   : $HEAD"
if [ "$B0" = "$GENHASH" ]; then echo "Rollback OK (canonical genesis)."; else echo "!! Verify chain identity."; fi
echo "Also roll back US: bash /root/us-stratum-rollback.sh --confirm GO"
