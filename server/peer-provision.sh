#!/bin/bash
set -euo pipefail

IP="${1:-}"
P2P_PORT="${2:-30303}"
KEY="${3:-}"

if [[ -z "$IP" || -z "$KEY" ]]; then
    echo '{"status":"error","error":"Missing args"}'
    exit 1
fi
if [[ ! "$P2P_PORT" =~ ^[0-9]+$ ]]; then
    echo '{"status":"error","error":"Invalid p2p_port"}'
    exit 1
fi

PEERS_DIR="/opt/ethii-peers"
mkdir -p "$PEERS_DIR"
PEER_CONF="$PEERS_DIR/$IP.conf"

echo "IP=$IP" > "$PEER_CONF"
echo "P2P_PORT=$P2P_PORT" >> "$PEER_CONF"
echo "KEY=$KEY" >> "$PEER_CONF"

if [[ "$IP" == *:* ]]; then
    nft list chain inet filter input | grep -Fq "ip6 saddr $IP tcp dport 30303 accept" || nft add rule inet filter input ip6 saddr "$IP" tcp dport 30303 accept
    nft list chain inet filter input | grep -Fq "ip6 saddr $IP udp dport 30303 accept" || nft add rule inet filter input ip6 saddr "$IP" udp dport 30303 accept
else
    nft list chain inet filter input | grep -Fq "ip saddr $IP tcp dport 30303 accept" || nft add rule inet filter input ip saddr "$IP" tcp dport 30303 accept
    nft list chain inet filter input | grep -Fq "ip saddr $IP udp dport 30303 accept" || nft add rule inet filter input ip saddr "$IP" udp dport 30303 accept
fi

nft list ruleset > /etc/nftables.conf

echo "{\"status\":\"ok\",\"source_ip\":\"$IP\",\"eu_p2p_port\":30303,\"msg\":\"peer firewall unlocked\"}"
