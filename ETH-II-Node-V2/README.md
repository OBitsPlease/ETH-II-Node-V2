# ETH-II Node V2 (Operator Baseline)

This repository is the clean baseline for ETH-II node and public pool operators.

> **Want to run a node or pool?** Fill out
> [`ops/templates/access-request-template.md`](ops/templates/access-request-template.md)
> and DM it to **`@bitspleaseyt.skr`** on Discord (or open a GitHub issue
> titled `Access request`). You'll get a download key for the binaries.

---

##  1. I want to run a mining pool (Linux VPS)

If you want to operate a public ETHII mining pool, we have a **fully automated one-click installer**. 

The installer will:
- Auto-generate a secure pool wallet
- Ask you which ports you want to use for miners
- Auto-provision a dedicated, lightweight Truth Node on our secure EU server
- Hook everything up seamlessly without any risk of chain forks

**Run this command on your Linux VPS (replace `YOUR_PASSKEY_HERE`):**

```bash
curl -sL https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh | sudo bash -s -- YOUR_PASSKEY_HERE
```

*Note: To update an existing pool, use `scripts/update-ethii-pool.sh`. If you are scaling to a second VPS, simply copy your `pool-keystore.json` to `/opt/ethii/` before running the installer!*

---

##  2. I want to run a Simple Peer Node (Windows PC)

Want to help the network grow without the complexity of running a pool? You can run a **Simple Peer Node** natively on your Windows PC in one click!

This node does **not** mine and does **not** run a pool. It simply syncs with the network and acts as a peer to strengthen the chain.

**How to run it:**
1. Download or clone this repository to your PC.
2. Double-click the `one-click-peer-node.bat` file in the folder.
3. It will ask for your **ETHII Passkey**.
4. The script will automatically download the Windows node binary, sync with the truth nodes, and start running in the background!

That's it! Your node is now supporting the network. Logs can be found in `%USERPROFILE%\ETHII\peer-node\data\peer-node.log`.

---

##  Security-first scope

Included:
- Canonical `genesis.json`
- Peer seed templates
- One-command pool installer (`scripts/setup-ethii-pool.sh`)
- Chain identity verification scripts

Not included:
- Chain database (`chaindata`, `ancient`, snapshots)
- Wallet keys or payout secrets
- Prebuilt binaries (these are gated behind the passkey system to prevent abuse)

## Canonical chain identity

Verify your node matches all three values before opening public services:
- net_version: `20482`
- eth_chainId: `0x800`
- genesis hash: `0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2`
