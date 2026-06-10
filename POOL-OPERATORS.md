# ETHII Pool Operator Guide

Run your own ETHII mining pool on a Linux server with one command. The
installer sets up a full ETHII node, the stratum pool software, a pool
wallet, automatic payouts, and self-healing services.

---

## 1. What you need

| Requirement | Details |
|---|---|
| Server | Linux (Ubuntu 22.04+ recommended), x86_64/amd64, root access |
| Specs | 2+ CPU cores, 4 GB RAM, 40 GB+ disk |
| Download key | Issued by the ETHII team — looks like `ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX` |

**About your download key:** the node and pool binaries are not published
publicly. The key you were given unlocks them from `https://www.ethii.net/dl/`.
Keep it private — it is tied to you. You only use it during install and
when updating.

## 2. Install (one command)

SSH into your server as root and run:

```bash
curl -fsSL -o setup-ethii-pool.sh https://raw.githubusercontent.com/OBitsPlease/ETH-II-Node-V2/main/scripts/setup-ethii-pool.sh
sudo bash setup-ethii-pool.sh ETHII-XXXXXXXX-XXXXXXXX-XXXXXXXX
```

(Replace the key with the one you were given.)

The installer:

1. Downloads the ETHII node and stratum binaries using your key
2. Downloads the official `genesis.json` and initializes the chain
3. Generates a **pool wallet** (keystore + password file) for payouts
4. Installs systemd services that restart automatically on crash
5. Installs a health guard that restarts anything that hangs (checked every 2 min)
6. Starts everything and **verifies the genesis hash** so you can't end up on the wrong chain

When it finishes it prints your pool wallet address and where the wallet
files live.

## 3. Back up your pool wallet (do this immediately)

The installer creates:

- `/opt/ethii/pool-keystore.json`
- `/opt/ethii/pool-password.txt`

Copy both files somewhere safe **off the server**. They control all pool
funds. If you lose them you cannot pay your miners; if someone steals them
they can take the pool's balance.

```bash
# from your own machine:
scp root@YOUR_SERVER:/opt/ethii/pool-keystore.json root@YOUR_SERVER:/opt/ethii/pool-password.txt ./ethii-pool-backup/
```

## 4. Open firewall ports

| Port | Protocol | Purpose | Required? |
|---|---|---|---|
| 30303 | TCP + UDP | Node peering (P2P) | Yes |
| 3333 | TCP | Miners — standard stratum | Yes |
| 3334 | TCP | Miners — low difficulty (CPU / small GPUs) | Optional |
| 3336 | TCP | Miners — Innosilicon A10 ASICs | Optional |
| 8082 | TCP | Pool web dashboard | Optional |

Example with ufw:

```bash
ufw allow 30303
ufw allow 3333/tcp
ufw allow 8082/tcp
```

**Never expose port 8545** (node RPC). The installer binds it to
127.0.0.1 only — leave it that way.

## 5. Point miners at your pool

Miners connect with their **own wallet address as the username**:

```
stratum+tcp://YOUR_SERVER_IP:3333
user: 0xMINER_WALLET_ADDRESS
pass: x
```

Example (lolMiner):

```bash
lolMiner --algo ETHASH --pool YOUR_SERVER_IP:3333 --user 0xMINER_WALLET_ADDRESS
```

### PPLNS vs solo

- **Default (PPLNS):** all miners share block rewards proportionally to
  recent shares. Steady income for everyone.
- **Solo:** a miner who wants to keep whole blocks for themselves prefixes
  their address with `solo:`

```
user: solo:0xMINER_WALLET_ADDRESS
```

## 6. Payouts

Payouts are fully automatic — you do not need to do anything:

- The node mines block rewards into your pool wallet
- The stratum checks balances every 30 seconds and pays any miner owed
  **0.1 ETHII or more**, signing transactions with the pool wallet
- PPLNS balances and payout history survive restarts

You can watch payouts in the logs:

```bash
journalctl -u ethii-stratum -f | grep payout
```

### Dev fee disclosure

ETHII has a **1% development fee built into the chain consensus** — 1% of
each block reward goes to the development fund address automatically. This
is enforced at the protocol level on every pool and solo miner equally;
it is not something your pool adds or can change.

## 7. Dashboard

Your pool has a live web dashboard at:

```
http://YOUR_SERVER_IP:8082
```

It shows connected miners, hashrate, blocks found, and pending balances,
and lets you adjust the minimum payout.

## 8. Day-to-day operation

The pool runs itself. Services restart on crash (systemd) and on hang
(health guard timer). Useful commands:

```bash
# status
systemctl status ethii-node ethii-stratum

# live logs
journalctl -u ethii-stratum -f
journalctl -u ethii-node -f

# health guard activity
journalctl -t ethii-guard

# is the node synced? (compare to the explorer at https://www.ethii.net)
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545
```

## 9. Updating

When a new version is announced, re-download the binaries with your key
and restart:

```bash
systemctl stop ethii-stratum ethii-node
curl -fsSL -o /opt/ethii/ethii   "https://www.ethii.net/dl/ethii-linux-amd64?key=YOUR_KEY"
curl -fsSL -o /opt/ethii/stratum "https://www.ethii.net/dl/stratum-linux-amd64?key=YOUR_KEY"
chmod +x /opt/ethii/ethii /opt/ethii/stratum
systemctl start ethii-node ethii-stratum
```

Your chain data, pool wallet, and payout state are untouched by updates.

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| Install fails at download | Check your key is correct and not expired — contact the ETHII team |
| `GENESIS MISMATCH` at install | You somehow got the wrong genesis.json — re-download the script and retry |
| Node not syncing / 0 peers | Open 30303 TCP+UDP in your firewall and your provider's cloud firewall |
| Miners can't connect | Open 3333/tcp; check `systemctl status ethii-stratum` |
| Payouts not sending | `journalctl -u ethii-stratum | grep payout` — usually pool wallet balance is still below what's owed; rewards accumulate as blocks are found |
| Dashboard unreachable | Open 8082/tcp, or keep it closed and tunnel: `ssh -L 8082:127.0.0.1:8082 root@server` |
| Everything stuck | `systemctl restart ethii-node ethii-stratum` — state is persistent, restarts are always safe |

Still stuck? Send the output of
`journalctl -u ethii-node -n 50 --no-pager; journalctl -u ethii-stratum -n 50 --no-pager`
to the ETHII team.

## Security notes

- Node RPC (8545) is local-only; the stratum arms the node for **remote
  work serving only — it never CPU-mines on your server**
- The pool wallet files are created with owner-only permissions (0600)
- The stratum has no remote send/withdraw API — payout transactions are
  signed locally and only pay miners what PPLNS accounting says they're owed
