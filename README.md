# ETH-II Node V2 (Operator Baseline)

This repository is the clean baseline for ETH-II node and public pool operators.

## Controlled access model

To reduce abuse risk while peer count is still growing:

- This public repo contains docs/templates only.
- Operator binaries are distributed by admin approval.
- Each approved operator gets an `OP-XXXX` ID and must submit a startup check-in.

See:
- `ops/POLICY.md`
- `ops/templates/access-request-template.md`
- `ops/templates/startup-checkin-template.md`

On this PC, use the local registry manager to track operators:

- Double-click `ops/operator-registry-manager.bat`
- Or run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\operator-registry-manager.ps1`

Registry file:
- `ops/operator-registry.json`

## Security-first scope

Included:
- Canonical `genesis.json`
- Peer seed templates
- Systemd service templates
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
- genesis hash: `0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf`

Use:
- `scripts/verify-chain.sh` (Linux)
- `scripts/verify-chain.ps1` (Windows)

## Quick start (Linux node)

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

5. Install service template from `templates/systemd/` and customize:
- `<EXT_IP>`
- `<ETHERBASE>`
- `<DATA_DIR>`

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

## Public pool notes

For pool operators, also deploy stratum from `templates/systemd/ethii-stratum.service.template` and verify chain identity before opening pool ports.

## Linux pool quickstart (operators)

Use this section if you want to run a public pool on Linux.

1. Place binaries:
- /root/ethii
- /root/stratum
- chmod +x /root/ethii /root/stratum

2. Prepare data and config:

```bash
mkdir -p /root/ethii-data /root/.ethereum
cp genesis.json /root/genesis.json
cp templates/config.toml /root/ethii-data/config.toml
cp p2p/static-nodes.json /root/.ethereum/static-nodes.json
cp p2p/trusted-nodes.json /root/.ethereum/trusted-nodes.json
```

3. Initialize chain data once:

```bash
/root/ethii --datadir /root/ethii-data --state.scheme hash init /root/genesis.json
```

4. Install services from templates:
- templates/systemd/ethii-node.service.template
- templates/systemd/ethii-stratum.service.template

Replace placeholders:
- <DATA_DIR> with /root/ethii-data
- <EXT_IP> with your server public IP
- <ETHERBASE> with your pool payout address

Save as:
- /etc/systemd/system/ethii-node.service
- /etc/systemd/system/ethii-stratum.service

5. Start services:

```bash
systemctl daemon-reload
systemctl enable --now ethii-node
systemctl enable --now ethii-stratum
```

6. Verify chain identity and ports:

```bash
./scripts/verify-chain.sh
ss -lntp | egrep ':30303|:3335|:3336|:3334|:8082'
```

Expected pool endpoint for miners:
- your-server-ip:3335

## Linux troubleshooting (pool connection issues)

If no miners can connect, run these checks in order.

1. Service health:

```bash
systemctl is-active ethii-node
systemctl is-active ethii-stratum
journalctl -u ethii-node -n 80 --no-pager
journalctl -u ethii-stratum -n 120 --no-pager
```

2. Chain identity (must match):

```bash
./scripts/verify-chain.sh
```

3. RPC responsiveness (stratum depends on fast local RPC):

```bash
for i in 1 2 3; do
	time curl -sS -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545
done
```

If this is slow or timing out, miners may show pool dead.

4. P2P and stratum listening ports:

```bash
ss -lntup | egrep ':30303|:3335|:3336|:3334|:8082|:8545'
```

5. Firewall rules (open these):
- 30303/tcp
- 30303/udp
- 3335/tcp
- 3336/tcp
- 3334/tcp

For UFW:

```bash
ufw allow 30303/tcp
ufw allow 30303/udp
ufw allow 3335/tcp
ufw allow 3336/tcp
ufw allow 3334/tcp
ufw status
```

6. Confirm stratum sees real miner traffic:

```bash
journalctl -u ethii-stratum -n 200 --no-pager | egrep 'eth_submitLogin|eth_submitWork|Share accepted|Share rejected|getWork error'
```

7. Common root causes when no one can connect:
- Wrong chain identity (not net_version 20482 and chainId 0x800)
- Node RPC stalled, causing stratum getWork timeouts
- Firewall/NAT not forwarding 3335
- Miner pointed to wrong host or port

## Admin operations on this PC

Use the registry manager for controlled onboarding:

1. Add approved operator (creates `OP-XXXX`).
2. Record startup check-in (IP, enode, chain identity).
3. Auto-quarantine if chain identity mismatches.
4. Set status (`active`, `paused`, `blocked`, `quarantine`).
5. Export CSV report for backups/audit.

If interrupted or restarted, current setup progress is tracked in:
- `ops/SETUP-STATUS.md`
