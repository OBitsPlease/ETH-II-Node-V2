# ETH-II Node V2 Manifest

This baseline intentionally excludes runtime chain data, private keys, and bundled binaries.

## Included
- `genesis.json` (canonical)
- `p2p/static-nodes.json`
- `p2p/trusted-nodes.json`
- `templates/config.toml`
- `templates/systemd/ethii-node.service.template`
- `templates/systemd/ethii-stratum.service.template`
- `scripts/verify-chain.sh`
- `scripts/verify-chain.ps1`

## Canonical identity checks
- net_version: `20482`
- eth_chainId: `0x800`
- genesis hash: `0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf`

## Genesis file hash
- SHA256: `4D941EE74D7400517193427549125763AF4BD7D7D846DC4A7AE98E7FDEF8DA0E`
