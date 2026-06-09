#!/usr/bin/env bash
set -euo pipefail
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
EXPECT_NET="20482"
EXPECT_CHAIN="0x800"
EXPECT_GENESIS="0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf"

rpc() {
  local method="$1"
  curl -sS -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":[],\"id\":1}" "$RPC_URL"
}

NET=$(rpc net_version | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
CHAIN=$(rpc eth_chainId | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
GENESIS=$(rpc admin_nodeInfo | sed -n 's/.*"genesis":"\([^"]*\)".*/\1/p')

echo "net_version=$NET"
echo "eth_chainId=$CHAIN"
echo "genesis=$GENESIS"

[[ "$NET" == "$EXPECT_NET" ]] || { echo "FAIL net_version"; exit 1; }
[[ "$CHAIN" == "$EXPECT_CHAIN" ]] || { echo "FAIL eth_chainId"; exit 1; }
[[ "$GENESIS" == "$EXPECT_GENESIS" ]] || { echo "FAIL genesis"; exit 1; }

echo "PASS canonical ETH-II chain identity" 
