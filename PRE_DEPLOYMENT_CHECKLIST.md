# Pre-Deployment Checklist for payout-daemon-final.go

## Issues Fixed in This Version:
- ✅ Uses `eth_sendRawTransaction` (locally signed) instead of `eth_sendTransaction` (requires account unlock)
- ✅ No longer requires `personal_unlockAccount` on node
- ✅ Signs transactions locally with your private key via go-ethereum ECDSA
- ✅ Reads block-finders.json to determine actual block finders (not blockchain miner field)
- ✅ Initializes to current block, doesn't process entire history
- ✅ PPLNS miners only paid when PPLNS miners find blocks (via block-finders.json `solo: false`)

## On VPS Before Deploying - Verify State Files Exist:
```bash
ssh root@87.99.142.128

# Check files
ls -lah /root/pplns_state.json /root/payout-history.json /root/block-finders.json

# Reset state if corrupted (fresh start):
echo '{"balances": {}, "paidBlocks": []}' > /root/pplns_state.json
```

## Key Difference from Previous Versions:
**Previous broken versions**: Tried to determine who found each block by querying stratum API or blockchain, failed because blockchain shows pool wallet for all blocks.

**This version**: Directly reads `/root/block-finders.json` which stratum writes in real-time as blocks are found. This is the single source of truth for block attribution.

Example block-finders.json entry:
```json
{"block": 52043, "address": "0x4B650688274A78B715E5cC055472D330e23F1a36", "worker": "1a36/pb1", "solo": false, "at": "2026-06-19T01:23:45Z"}
```

The daemon processes this entry and queues a 4.9 ETHII payout to 0x4B65... when block 52043 is confirmed.

## Expected Behavior After Deploy:
1. Daemon starts and loads last processed block from pplns_state.json
2. Every 15 seconds, checks current block height
3. For each new block since last processed:
   - Looks up who found it in block-finders.json
   - If found: adds 4.9 ETHII to that miner's balance
   - If balance >= 0.1 ETHII: immediately signs and sends transaction
   - Records to payout-history.json with transaction hash
4. Logs show: `[payout] SENT 4.90 ETHII to 0x4B65... (tx: 0xabc...)`

## Command to Deploy (Copy & Paste):
```bash
# From your local machine:
scp stratum/payout-daemon-final.go root@87.99.142.128:/root/payout-daemon.go && \
ssh root@87.99.142.128 'cd /root && go build -o payout-daemon payout-daemon.go && \
systemctl stop payout-daemon; \
cat > /etc/systemd/system/payout-daemon.service <<EOF
[Unit]
Description=ETHII Pool Payout Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/root/payout-daemon
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && \
systemctl enable payout-daemon && \
systemctl start payout-daemon && \
echo "Daemon deployed and started. Checking logs..." && \
journalctl -u payout-daemon -n 20'
```

## If Something Goes Wrong:
```bash
# Check logs
ssh root@87.99.142.128 'journalctl -u payout-daemon -f'

# Stop daemon
ssh root@87.99.142.128 'systemctl stop payout-daemon'

# Check state files
ssh root@87.99.142.128 'cat /root/payout-history.json | jq . | tail -20'
ssh root@87.99.142.128 'cat /root/pplns_state.json | jq .'
```
