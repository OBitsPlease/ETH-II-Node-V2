# ETH-II Node V2 (Operator Baseline)

This repository is the clean baseline for ETH-II node and public pool operators.

> **Want to run a node or pool?** Fill out
> [`ops/templates/access-request-template.md`](ops/templates/access-request-template.md)
> and DM it to **`@bitspleaseyt.skr`** on Discord (or open a GitHub issue
> titled `Access request`). You'll get a download key for the binaries.

## Pool operators: start here

**[POOL-OPERATORS.md](POOL-OPERATORS.md)** — one-command install of a
self-running ETHII pool (node + stratum + auto-payouts + self-healing).
You need a download key from the ETHII team.

## Controlled access model

To reduce abuse risk while peer count is still growing:

- This public repo contains docs/templates only.
- Operator binaries are distributed by admin approval.
- Each approved operator gets an `OP-XXXX` ID and must submit a startup check-in.

See:
- `ops/POLICY.md`
- `ops/templates/access-request-template.md`
- `ops/templates/startup-checkin-template.md`

## Getting the binaries (access key required)

Node and stratum binaries are served from the official gated download service, not from GitHub:

1. Request access: open an issue on this repo titled `Access request` using `ops/templates/access-request-template.md`, or use the contact info on https://www.ethii.net
2. You will receive a personal key (`ETHII-XXXX-XXXX-XXXX`). Do not share it — every download is logged per key and keys can be revoked.
3. Download:
   - `https://www.ethii.net/dl/ethii-linux-amd64?key=YOUR-KEY`
   - `https://www.ethii.net/dl/ethii-windows-amd64.exe?key=YOUR-KEY`
   - `https://www.ethii.net/dl/stratum-linux-amd64?key=YOUR-KEY`
   - `https://www.ethii.net/dl/stratum-windows-amd64.exe?key=YOUR-KEY`

Example (Linux):

```bash
curl -fL -o /root/ethii "https://www.ethii.net/dl/ethii-linux-amd64?key=YOUR-KEY"
chmod +x /root/ethii
```

On this PC, use the local registry manager to track operators:

- Double-click `ops/operator-registry-manager.bat`
- Or run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\operator-registry-manager.ps1`

Registry file:
- `ops/operator-registry.json`

## Security-first scope

Included:
- Canonical `genesis.json`
- Peer seed templates
- One-command pool installer (`scripts/setup-ethii-pool.sh`)
- Chain identity verification scripts

Not included:
- Chain database (`chaindata`, `ancient`, snapshots)
- Wallet keys or payout secrets
- Legacy mixed files from previous repos
- Prebuilt binaries in the public repository

## Canonical chain identity

Verify your node matches all three values before opening public services:
- net_version: `20482`
- eth_chainId: `0x800`
- genesis hash: `0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2`

Use:
- `scripts/verify-chain.sh` (Linux)
- `scripts/verify-chain.ps1` (Windows)

## Quick start (Linux peer node, no pool)

Use this if you only want to run a node to support the network. To run a
pool, use [POOL-OPERATORS.md](POOL-OPERATORS.md) instead.

1. Place `ethii` binary at `/root/ethii` and make it executable.
2. Create datadir `/root/ethii-data`.
3. Initialize genesis:

```bash
/root/ethii --datadir /root/ethii-data --state.scheme hash init ./genesis.json
```

4. Copy peer templates:

```bash
mkdir -p /root/.ethereum
cp p2p/static-nodes.json /root/.ethereum/static-nodes.json
cp p2p/trusted-nodes.json /root/.ethereum/trusted-nodes.json
cp templates/config.toml /root/ethii-data/config.toml
```

5. Create `/etc/systemd/system/ethii-node.service`:

```ini
[Unit]
Description=ETHII Node
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=/root/ethii --config /root/ethii-data/config.toml --datadir /root/ethii-data --networkid 20482 --syncmode full --snapshot=false --state.scheme hash --port 30303 --maxpeers 50
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

6. Start node and verify:

```bash
systemctl daemon-reload
systemctl enable --now ethii-node
./scripts/verify-chain.sh
```

## Windows one-click (network support only)

Use this mode if you only want to help network peer count.

This does:
- Start a node for peer connectivity.
- Verify canonical chain identity.

This does not:
- Run stratum.
- Host a public mining pool.

### Steps

1. Download or clone this repository.
2. Put `ethii.exe` in the repository root (same folder as `genesis.json`).
3. Double-click `one-click-peer-node.bat`.
4. Wait for the script to report `PASS canonical ETH-II chain identity`.

The launcher starts a node using a local datadir:
- `%USERPROFILE%\\ETHII\\peer-node\\data`

Logs are written to:
- `%USERPROFILE%\\ETHII\\peer-node\\data\\peer-node.log`

To check identity manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-chain.ps1
```

## Running a public pool

Use the one-command installer — see **[POOL-OPERATORS.md](POOL-OPERATORS.md)**.
It sets up the node, stratum, pool wallet, automatic payouts, and
self-healing services, and includes firewall, miner-setup, and
troubleshooting guidance.

## Admin operations on this PC

Use the registry manager for controlled onboarding:

1. Add approved operator (creates `OP-XXXX`).
2. Record startup check-in (IP, enode, chain identity).
3. Auto-quarantine if chain identity mismatches.
4. Set status (`active`, `paused`, `blocked`, `quarantine`).
5. Export CSV report for backups/audit.

If interrupted or restarted, current setup progress is tracked in:
- `ops/SETUP-STATUS.md`
