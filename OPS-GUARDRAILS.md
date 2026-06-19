ETHII Operations Guardrails (Hard Safety Rules)

Purpose
- Prevent accidental chain/network drift and prevent unsafe VPS edits.

Non-Negotiable Rules
- Expected network id (net_version): 20482
- Expected genesis hash (block 0): 0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2
  (chain cutover 2026-06-10 ~05:40 UTC: new genesis, chainId 20482; previous hash 0x6836fa7f... is obsolete)
- Never re-init VPS datadirs.
- Never replace VPS genesis files.
- Never edit VPS chain config unless explicitly requested in writing in this session.
- Always run safety preflight before any VPS write action.

Session Startup Prompt (copy into first message each session)
I authorize read-only diagnostics by default. Do not perform any write action on VPS nodes unless I explicitly say: APPROVE VPS WRITE NOW. Before any VPS write action, run preflight-ethii-safety.ps1 and show net_version and block 0 hash for both VPS nodes. Expected net_version is 20482 and expected block 0 hash is 0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2. If either check fails, stop and ask me.

Operator Checklist
- Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\preflight-ethii-safety.ps1
- If all checks pass, proceed.
- If any check fails, stop and investigate before changes.

Incident Rule
- If an assistant ever suggests changing chain id/genesis, stop immediately and run preflight-ethii-safety.ps1.
- Treat any chain id/genesis mismatch as a release-blocking incident.

Binary Distribution Rules (added 2026-06-10)
- Node/stratum binaries are NEVER published to public GitHub repos (no release assets, no committed binaries).
- Public repos (ETH-II-Node-V2, ETH-II-Data-for-Public-Pools) are docs/templates only.
- Binaries are served only by the gated download service on EU VPS 91.99.231.217:
  - Service: /opt/ethii-downloads/serve.py (systemd unit ethii-downloads, 127.0.0.1:8090, nginx /dl/ proxy)
  - Keys: /opt/ethii-downloads/keys.json - manage with `ethii-keys` (list/add/revoke/unrevoke/log) on the VPS,
    or the "ETHII Key Manager" desktop icon on this PC.
  - Every download is logged per key in /opt/ethii-downloads/download.log
- Before adding new binaries to the download dir, verify them against locally built artifacts (sha256).
- If a key leaks, revoke it immediately: ssh root@91.99.231.217 "ethii-keys revoke <KEY>"
- Wallet releases stay public on ETH-II-Wallet-V2 (wallet is for end users, not gated).

