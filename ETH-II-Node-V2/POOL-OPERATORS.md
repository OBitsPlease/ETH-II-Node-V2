# ETHII Mining Pool Operator Guide

**Run your own ETHII mining pool — complete setup in one command.**

This guide helps you set up a mining pool on a Linux server. The installer will:
- Download the ETHII node and pool software
- Create your pool wallet automatically
- Start the pool
- **Set up automatic payouts** to miners every 30 seconds (no extra work needed)

---

## Quick Start (Fastest Way)

If you have a Linux server with 4GB RAM and your download key, you can have a pool running in 3 minutes:

```bash
# SSH into your server as root, then paste this one command:
curl -fsSL https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh | bash -s YOUR_DOWNLOAD_KEY
```

Replace `YOUR_DOWNLOAD_KEY` with the key you received (looks like `ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX`).

**That's it.** When it finishes, your pool is running and miners can connect.

---

## What You Need (Before Starting)

### 1. A Linux Server

You need one dedicated Linux server (Ubuntu 22.04+ recommended):
- **Where to get one:** Hetzner, Linode, DigitalOcean, AWS, or any VPS provider
- **Minimum specs:** 2 CPU cores, 4 GB RAM, 50 GB disk space
- **Cost:** Usually $10-30/month
- **Access:** You need to be able to SSH in as root (or with sudo access)

### 2. Your Download Key

You should have received a download key from the ETHII team. It looks like:
```
ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX
```

Keep this private — it's your personal key to download the pool software. You'll use it during setup.

### 3. (Optional) A VPS Control Panel Account

Most VPS providers give you a control panel (web browser login) where you can:
- Reboot your server
- View console logs
- Take snapshots

This is helpful if something goes wrong, but not required.

---

## Step-by-Step Setup (Detailed Version)

### Step 1: Rent a Linux Server

Go to a VPS provider (Hetzner, Linode, DigitalOcean, etc.) and create a new server:
- **OS:** Ubuntu 22.04 LTS
- **Size:** 2+ vCPU, 4+ GB RAM
- **Disk:** 50+ GB SSD
- **Region:** Anywhere (but closer to miners is faster)

Note down:
- Your server's **IP address** (e.g., `123.45.67.89`)
- Your **root password** (or SSH key if provided)

### Step 2: Connect to Your Server

On your home computer, open a terminal/command prompt:

**On Mac or Linux:**
```bash
ssh root@YOUR_SERVER_IP
# It will ask for password — paste the password from step 1
```

**On Windows:**
- Download PuTTY (free SSH program)
- Host: `YOUR_SERVER_IP`
- Click Open, login as `root` with your password

You should now see a command prompt on the server.

### Step 3: Run the Pool Setup Script

In the SSH terminal, copy and paste this entire command:

```bash
curl -fsSL https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh | bash -s YOUR_DOWNLOAD_KEY
```

Replace `YOUR_DOWNLOAD_KEY` with your actual key (e.g., `ETHII-abc123def456ghi789`).

Press Enter and let it run. You'll see output like:
```
==> Pre-flight safety checks...
==> Downloading ETHII node binary...
==> Downloading ETHII stratum binary...
...
```

**This takes 3-5 minutes.** Don't close the terminal.

### Step 4: Wait for Completion

When it finishes, you'll see:
```
============================================================
 ETHII pool installed and running.
============================================================
 Pool wallet     : 0xbAA2144...
   Dashboard       : http://YOUR_SERVER_IP:8082
 Payouts run automatically (PPLNS, 0.1 ETHII minimum).
============================================================
```

**Save this output** — your pool wallet address and dashboard URL are important.

### Step 5: Tell Your Miners

Give your miners this connection info:

```
Pool: YOUR_SERVER_IP:3335
Wallet: 0xTHEIR_ETHEREUM_ADDRESS
Password: x
```

For example, with lolMiner:
```bash
lolMiner --algo ETHASH --pool YOUR_SERVER_IP:3335 --user 0xTHEIR_WALLET_ADDRESS
```

---

## Your Pool is Running — What Happens Now?

### Dashboard
Visit `http://YOUR_SERVER_IP:8082` in your browser. You'll see:
- Connected miners
- Blocks found
- Miner balances
- Live stats

### Automatic Payouts
The pool **automatically pays out** every 30 seconds:
- When a miner earns **0.1 ETHII or more**, they get paid automatically
- No action needed from you
- Check the dashboard to see pending payouts

### View Logs
To see what the pool is doing, in your SSH terminal run:
```bash
journalctl -u ethii-stratum -f
```

You'll see miner connections, blocks found, and payouts. Press `Ctrl+C` to stop viewing.

---

## Backing Up Your Pool Wallet

**IMPORTANT:** Your pool wallet is created during setup. If you lose it, you lose access to all pool funds.

The wallet files are at:
- `/opt/ethii/pool-keystore.json` — your wallet file
- `/opt/ethii/pool-password.txt` — the password that unlocks it

**Back them up immediately:**

On your home computer:
```bash
scp root@YOUR_SERVER_IP:/opt/ethii/pool-keystore.json ./ethii-backup/
scp root@YOUR_SERVER_IP:/opt/ethii/pool-password.txt ./ethii-backup/
```

Store these files somewhere safe (another computer, USB drive, etc.). **Keep them private.**

---

## Troubleshooting

### "Pool won't start" or "Port already in use"

The server has another service using the pool's ports. Fix:
```bash
systemctl status ethii-stratum
journalctl -u ethii-stratum -n 20
```

If the install failed, remove the old install:
```bash
systemctl stop ethii-stratum ethii-node
rm -rf /opt/ethii
```

Then re-run the setup script.

### "Miners can't connect"

Your firewall is blocking port 3335. Check with your VPS provider's firewall settings and open:
- Port 30303 (TCP + UDP) — node communication
- Port 3335 (TCP) — miners
- Port 8082 (TCP) — dashboard (optional)

### "Payouts aren't working"

Check the logs:
```bash
journalctl -u ethii-stratum | grep payout
```

Usually this means:
- Pool wallet balance is too low (blocks haven't been found yet)
- Miner balance is below 0.1 ETHII (minimum payout)

**Wait** — miners earn blocks, balance accumulates, payouts happen automatically.

### "Node not syncing / behind on blocks"

Check if connected to the network:
```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545 | grep result
```

Make sure port 30303 is open (TCP+UDP) in your firewall for peer connections.

### "Dashboard shows wrong hashrate"

ASIC miners report hashrate differently. The dashboard applies a correction — this is normal. Actual mining power is correct.

### Still stuck?

Run this to get diagnostic info:
```bash
systemctl status ethii-node ethii-stratum
journalctl -u ethii-node -n 20
journalctl -u ethii-stratum -n 20
```

Share the output with the ETHII team.

---

## Important Notes

### Do NOT Change These

- **RPC endpoint:** Always `91.99.231.217:8545` (canonical node) — don't change it
- **Network ID:** Always 20482
- **Payouts:** Fully automatic via stratum — don't modify

Changing these breaks the network consensus.

### Miner Connection Ports

- **Port 3335** — Standard miners (GPUs, most hardware)
- **Port 3334** — Low difficulty (CPU, small GPUs)
- **Port 3336** — Innosilicon A10 ASICs

All three are open by default.

### PPLNS Payouts

Your pool uses **PPLNS** (Pay Per Last N Shares):
- All connected miners share block rewards **proportionally** to work submitted
- If a solo miner finds a block alone, they get the full reward
- Minimum payout: 0.1 ETHII (to keep fees reasonable)

### Development Fee

ETHII has a **1% development fee built into consensus** (enforced by the chain, not the pool). This applies equally to all pools and solo miners.

---

## Advanced: Manual Setup (If Script Doesn't Work)

If the one-command setup fails, you can set up manually:

```bash
# 1. Create directory
mkdir -p /opt/ethii
cd /opt/ethii

# 2. Download files (replace YOURKEY with your download key)
curl -fsSL -o ethii "https://www.ethii.net/dl/ethii-linux-amd64?key=YOURKEY"
curl -fsSL -o stratum "https://www.ethii.net/dl/stratum-linux-amd64?key=YOURKEY"
chmod +x ethii stratum

# 3. Get genesis file
curl -fsSL -o genesis.json https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/genesis.json

# 4. Initialize database
./ethii --datadir /opt/ethii/data --state.scheme hash init genesis.json

# 5. Generate pool wallet
./stratum -init-wallet -keystore /opt/ethii/pool-keystore.json -passfile /opt/ethii/pool-password.txt

# 6. Start node
./ethii --datadir /opt/ethii/data --networkid 20482 --gcmode archive --state.scheme hash \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3 &

# 7. Start pool (wait 30 seconds for node to start first)
sleep 30
./stratum -node http://91.99.231.217:8545 -stratum 0.0.0.0:3335 -a10-stratum 0.0.0.0:3336 \
  -lowdiff-stratum 0.0.0.0:3334 -etherbase 0xYOUR_POOL_ADDRESS \
  -settings /opt/ethii -keystore /opt/ethii/pool-keystore.json -passfile /opt/ethii/pool-password.txt \
  -dashboard 0.0.0.0:8082 &
```

---

## Questions?

For help:
- Check pool logs: `journalctl -u ethii-stratum -n 50`
- Check node logs: `journalctl -u ethii-node -n 50`
- Contact the ETHII team with the output above

**Your pool is now running. Miners can connect and earn blocks. Payouts happen automatically.**
