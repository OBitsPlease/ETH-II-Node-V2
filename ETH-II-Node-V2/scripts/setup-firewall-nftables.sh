#!/usr/bin/env bash
# ETHII firewall configuration for nftables (Hetzner/modern Linux)
# Run after setup-ethii-pool.sh completes
# Usage: sudo bash setup-firewall-nftables.sh

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" = "0" ] || err "run as root (sudo)"
command -v nft >/dev/null || err "nftables is required (apt install nftables)"

info "Configuring nftables firewall for ETHII pool..."
info "WARNING: This will modify your firewall rules. Backup first if unsure."
echo

read -p "  Continue? Type 'yes': " confirm
[ "$confirm" = "yes" ] || err "Cancelled"

info "Creating nftables ruleset for ETHII..."

nft flush ruleset 2>/dev/null || true

nft 'create table inet ethii' 2>/dev/null || true
nft 'flush table inet ethii'

# Create chains
nft 'add chain inet ethii input { type filter hook input priority 0; policy drop; }'
nft 'add chain inet ethii forward { type filter hook forward priority 0; policy drop; }'
nft 'add chain inet ethii output { type filter hook output priority 0; policy accept; }'

# Allow loopback
nft 'add rule inet ethii input iifname lo accept'

# Allow established connections
nft 'add rule inet ethii input ct state established,related accept'

# Allow SSH (preserve access!)
nft 'add rule inet ethii input tcp dport 22 accept'

# ETHII Node P2P peering
nft 'add rule inet ethii input tcp dport 30303 accept'
nft 'add rule inet ethii input udp dport 30303 accept'

# Stratum mining pools
nft 'add rule inet ethii input tcp dport 3335 accept'   # Standard
nft 'add rule inet ethii input tcp dport 3334 accept'   # Low-difficulty
nft 'add rule inet ethii input tcp dport 3336 accept'   # A10 ASIC

# Pool dashboard
nft 'add rule inet ethii input tcp dport 8082 accept'

# ICMP (ping)
nft 'add rule inet ethii input icmp type echo-request accept'
nft 'add rule inet ethii input icmpv6 type echo-request accept'

info "Firewall rules applied:"
echo "  ✓ SSH (22) - always open"
echo "  ✓ Node P2P (30303 TCP+UDP)"
echo "  ✓ Stratum Standard (3335 TCP)"
echo "  ✓ Stratum Low-Diff (3334 TCP)"
echo "  ✓ Stratum A10 ASIC (3336 TCP)"
echo "  ✓ Dashboard (8082 TCP)"
echo "  ✓ ICMP (ping)"
echo

info "Saving ruleset..."
nft list ruleset > /etc/nftables.conf

info "Enabling nftables service..."
systemctl enable nftables
systemctl restart nftables

info "Firewall configured and saved to /etc/nftables.conf"
info "Ruleset will persist after reboot."
