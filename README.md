# ETHII — ETH 2.0 Proof of Work
## Setup & Mining Guide

---

## What is ETHII?
ETHII (ETH 2.0) is a proof-of-work Ethereum fork that keeps mining alive forever.
- **Chain ID:** 2048
- **Block time:** ~10 seconds
- **Block reward:** 5 ETHII (fixed forever, no halving)
- **Gas price:** 0.5 gwei base (half of ETH)
- **Supply:** Unlimited (no cap)
- **Consensus:** Ethash (GPU mineable)

---

## Part 1 — Wallet Only Install
*Just want to send/receive ETHII? Use this.*

1. Double-click **ETHII Wallet** on your desktop
2. Click **Create New Wallet** and set a strong password
3. **SAVE YOUR PRIVATE KEY AND MNEMONIC** — there is no recovery without them
4. Your wallet address starts with `0x` — share this to receive ETHII

---

## Part 2 — Miner Install
*Run a node and mine ETHII.*

### What launches when you click ETHII Miner Suite:
| Window | What it does |
|--------|-------------|
| ETHII Wallet | GUI wallet for your mined coins |
| ETHII Stratum | Stratum proxy on port 3333 |
| Node console | ethii.exe — syncs chain and mines |

### First launch:
1. Double-click **ETHII Miner Suite** on your desktop
2. Open the Stratum dashboard (http://127.0.0.1:8082)
3. In **Payout Settings**, click **Generate From Wallet**
4. Click **Save Address** so the mining address is locked in
5. Do this **before connecting any external miner** (ASIC/GPU)
6. Three windows open: wallet GUI, stratum console, node console
7. Wait ~30 seconds for the node to initialize, then mining begins

### Important first-run rule (required):
- The user field in your ASIC/GPU miner can be a worker name (for example: `rig1`), but payout still depends on the saved mining address.
- Always click **Generate From Wallet** first on a fresh setup or after resets.

### Firewall / Ports:
| Port | Purpose |
|------|---------|
| 8545 | RPC (wallet ↔ node) — keep local only |
| 30303 | P2P node discovery — open this in your router/firewall |
| 3333 | Stratum — open this if other miners will connect to you |

---

## Solo Mining (your GPU, your node)

Point your GPU miner at your own stratum:

**PhoenixMiner:**
```
PhoenixMiner.exe -pool stratum+tcp://127.0.0.1:3333 -wal YOUR_ADDRESS -pass x
```

**lolMiner:**
```
lolMiner.exe --algo ETHASH --pool stratum+tcp://127.0.0.1:3333 --user YOUR_ADDRESS
```

**T-Rex:**
```
t-rex.exe -a ethash -o stratum+tcp://127.0.0.1:3333 -u YOUR_ADDRESS -p x
```

**GMiner:**
```
miner.exe --algo ethash --server 127.0.0.1 --port 3333 --user YOUR_ADDRESS
```

---

## Connecting from another PC on your network

Replace `127.0.0.1` with your mining PC's local IP (e.g. `192.168.20.10`):
```
PhoenixMiner.exe -pool stratum+tcp://192.168.1.100:3333 -wal YOUR_ADDRESS -pass x
```

---

## Running a Public Mining Pool

To allow anyone on the internet to mine ETHII on your pool:

1. Open port **3333** in your router (port forward to your mining PC)
2. Share your public IP or domain: `stratum+tcp://YOUR_IP:3333`
3. Start the **ETHII Miner Suite** — the stratum proxy handles all connections

The stratum proxy supports unlimited simultaneous miners.

---

## Adding ETHII to MetaMask or other wallets

| Field | Value |
|-------|-------|
| Network Name | ETHII |
| RPC URL | http://127.0.0.1:8545 (local) |
| Chain ID | 2048 |
| Symbol | ETHII |
| Block Explorer | (coming soon) |

---

## Troubleshooting

**Wallet shows "Node offline"**
→ Start ETHII Miner Suite first, wait 30 seconds, click Refresh in wallet

**Port 8545 already in use**
→ The wallet auto-detects and tries the next available port (8546, 8547...)

**Port 3333 already in use**
→ Edit `launch-stratum.bat` and change `3333` to another port (e.g. 3334)

**"ETHII_RUN_AS_NODE" / wallet won't open**
→ Always use `launch-wallet.bat` or the desktop shortcut, not `npm start`

---

## Genesis Block Message
The ETHII genesis block contains this permanent message:
> *"ETHII promise. ETH 2.0 will be mineable forever, signed BitsPleaseYT."*

---

*ETHII — ETH 2.0 will be mineable forever.*
