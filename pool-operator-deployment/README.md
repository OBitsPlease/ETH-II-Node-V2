# ETHII Mining Pool - Operator Deployment Package

⚠️ **DEPRECATED** — Use [ETH-II-Node-V2](../ETH-II-Node-V2) instead.

This is an old reference package. For:
- **Running a mining pool:** Use [ETH-II-Node-V2](../ETH-II-Node-V2) with `scripts/setup-ethii-pool.sh`
- **Running a node only:** Use [ETH-II-NODE-ONLY](../ETH-II-NODE-ONLY)

The setup script in ETH-II-Node-V2 automatically:
- Downloads binaries using your access key
- Generates a secure pool wallet
- Configures stratum to connect to the canonical RPC (91.99.231.217:8545)
- Sets up automatic payouts
- Installs health monitoring

---

## Old contents (for reference)

Complete, tested pool operator setup as of 2026-06-19.

## Contents

- **website/** - Node.js Express server + HTML/JS pool frontend
  - `server.js` - Working pool API server with ASIC hashrate correction (1.6x multiplier for solo miners)
  - `pool.html`, `explorer.html`, `pool-miners.html` - Dashboard and monitoring pages
  - `chain-wallets.json` - Wallet directory snapshot

- **config/** - Service and configuration files
  - `ethii-stratum.service` - Systemd service for stratum pool (points to EU RPC)
  - `miner-thresholds.json` - ASIC-specific configuration

- **backups/** - Complete VPS snapshots
  - `US-VPS-backup.tar.gz` - Production US pool setup
  - `EU-VPS-backup.tar.gz` - EU node backup

## Key Fixes Implemented

1. **Hashrate Correction**: Solo miners (ASICs) now show accurate hashrate (1.6x multiplier applied in server.js)
2. **Chain Stats API**: Added `/api/chain/stats` endpoint for explorer network stats
3. **Network Difficulty Display**: Explorer now shows network difficulty and hashrate
4. **Miner Tracking**: Proper attribution of blocks and shares to miners

## Important Notes

- **RPC Configuration**: Stratum service points to EU VPS (91.99.231.217:8545) as truth node
- **Hashrate Calculation**: Stratum underestimates solo ASIC hashrate by ~1.6x; website applies correction
- **Solo Mining**: All solo miners connected to port 3335 (standard stratum)
- **A10 ASIC Port**: Port 3336 for hardware ASICs
