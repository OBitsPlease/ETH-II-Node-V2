# ETHII Mining Pool - Operator Deployment Package

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

## Deployment Steps

1. Extract backups or copy files to `/root/website/` and `/root/` on pool VPS
2. Update `/etc/systemd/system/ethii-stratum.service` with correct RPC endpoints
3. Copy `miner-thresholds.json` to `/root/` (ASIC configuration)
4. Install Node.js dependencies: `npm install` in website directory
5. Start services:
   ```bash
   systemctl daemon-reload
   systemctl enable --now ethii-stratum
   systemctl enable --now ethii-website
   ```

## Important Notes

- **RPC Configuration**: Stratum service points to EU VPS (91.99.231.217:8545) as truth node
- **Hashrate Calculation**: Stratum underestimates solo ASIC hashrate by ~1.6x; website applies correction
- **Solo Mining**: All solo miners connected to port 3335 (standard stratum)
- **A10 ASIC Port**: Port 3336 for hardware ASICs

## Testing

```bash
# Check stratum API
curl http://127.0.0.1:8082/api/miners

# Check website API
curl http://localhost:3000/api/miners
curl http://localhost:3000/api/chain/stats

# Test website
curl https://your-domain/explorer.html
```

## Support

- Stratum binary: `/root/stratum` (compiled, pre-built)
- Website service: Node.js Express on port 3000
- Nginx proxy: Forwards HTTPS to localhost:3000
