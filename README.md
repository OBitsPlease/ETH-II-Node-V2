# ETH-II Node V2 (Operator Baseline)

## 🚨🚨🚨 STOP — RUN ONLY ONE OF THESE TWO OPTIONS 🚨🚨🚨

## ✅ **POOL OPERATOR (LINUX VPS) — RUN THIS**
```bash
wget -O setup-ethii-pool.sh "https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh?v=fresh"
sudo bash setup-ethii-pool.sh YOUR_PASSKEY_HERE
```

**Demo with fake key (example only):**
```bash
wget -O setup-ethii-pool.sh "https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh?v=fresh"
sudo bash setup-ethii-pool.sh ETHII-FAKEKEY1-FAKEKEY2-FAKEKEY3
```

---

## ✅ **PEER NODE ONLY (NO POOL) — RUN THIS**
```bash
wget -O setup-ethii-peer.sh "https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-peer.sh?v=fresh"
sudo bash setup-ethii-peer.sh YOUR_PASSKEY_HERE
```

**Demo with fake key (example only):**
```bash
wget -O setup-ethii-peer.sh "https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-peer.sh?v=fresh"
sudo bash setup-ethii-peer.sh ETHII-FAKEKEY1-FAKEKEY2-FAKEKEY3
```

---

## 🔑 Need a passkey first?
1. Join Discord: **https://discord.gg/fecncP66**
2. Tag/DM **@bitspleaseyt.skr** and request a key.

---

## What this repository is for

This repository is the clean baseline for ETH-II pool operators and peer-node operators.

- Pool installer: `scripts/setup-ethii-pool.sh`
- Peer installer: `scripts/setup-ethii-peer.sh`
- Pool updater: `scripts/update-ethii-pool.sh`
- Windows peer launcher: `one-click-peer-node.bat`

## Pool installer behavior

The pool installer:
- Prompts for custom miner/dashboard ports
- Generates or reuses pool wallet files
- Auto-provisions a dedicated EU tenant RPC (per pool)
- Starts `ethii-stratum` with your assigned tenant RPC port

## Peer installer behavior

The peer installer:
- Prompts for P2P/RPC/max-peers settings
- Installs a non-mining relay node
- Registers peer metadata with EU API
- Auto-unlocks required EU firewall rules for that peer IP

## Canonical chain identity

Verify your node matches:
- `net_version`: `20482`
- `eth_chainId`: `0x800`
- `genesis hash`: `0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2`
