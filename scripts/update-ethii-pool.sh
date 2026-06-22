#!/usr/bin/env bash
# ETHII pool updater for Linux (amd64).
# Usage: sudo bash update-ethii-pool.sh ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX

set -euo pipefail

DL_BASE="https://www.ethii.net/dl"
INSTALL_DIR="/opt/ethii"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

KEY="${1:-}"
[ -n "$KEY" ] || err "usage: sudo bash $0 <ETHII-download-key>"
[ "$(id -u)" = "0" ] || err "run as root (sudo)"

if ! systemctl is-active --quiet ethii-stratum 2>/dev/null; then
  info "ethii-stratum is not actively running, but proceeding with update anyway..."
fi

info "Stopping ETHII Stratum service..."
systemctl stop ethii-stratum

info "Downloading newest ETHII stratum binary..."
curl -fsSL -o "$INSTALL_DIR/stratum" "$DL_BASE/stratum-linux-amd64?key=$KEY" \
  || err "stratum download failed  check your download key"
chmod +x "$INSTALL_DIR/stratum"

info "Starting ETHII Stratum service..."
systemctl start ethii-stratum

info "Update complete! Checking status..."
systemctl status ethii-stratum --no-pager | head -n 10