# Deploy payout-daemon-final.go to US VPS

## On local machine:
1. Copy the daemon to deploy:
```bash
scp stratum/payout-daemon-final.go root@87.99.142.128:/root/payout-daemon.go
```

## On US VPS (87.99.142.128):
1. Compile:
```bash
cd /root && go build -o payout-daemon payout-daemon.go
```

2. Stop the old daemon (if running):
```bash
systemctl stop payout-daemon || pkill -f payout-daemon || true
```

3. Create systemd service `/etc/systemd/system/payout-daemon.service`:
```ini
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
```

4. Enable and start:
```bash
systemctl daemon-reload
systemctl enable payout-daemon
systemctl start payout-daemon
```

5. Verify:
```bash
journalctl -u payout-daemon -f
```

Watch for "[payout] SENT" messages confirming transactions.

## Verification checklist:
- [ ] Daemon starts without errors in logs
- [ ] Logs show blocks being processed from block-finders.json
- [ ] payout-history.json entries appear with txHash values
- [ ] Balances in pplns_state.json reset after payout
- [ ] Miner addresses receive ETHII from pool wallet
