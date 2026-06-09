# ETH-II Node V2 (Operator Baseline)

This repository is the clean baseline for ETH-II node and public pool operators.

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
- Prebuilt binaries (operators should use official release binaries)

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

## Public pool notes

For pool operators, also deploy stratum from `templates/systemd/ethii-stratum.service.template` and verify chain identity before opening pool ports.
