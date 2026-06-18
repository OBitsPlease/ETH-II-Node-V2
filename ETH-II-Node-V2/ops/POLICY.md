# ETH-II Controlled Operator Policy

## Goal

Keep chain participation open enough for growth while reducing unknown-risk operators.

## Distribution model

- Public repo: docs/templates only
- Controlled binaries: distributed via the gated download service at `https://www.ethii.net/dl/` using per-operator access keys
- Every key is individually issued, every download is logged per key, and keys can be revoked at any time

## Approval flow

1. Operator submits Access Request.
2. Admin assigns Operator ID (`OP-XXXX`).
3. Admin issues a personal download key (`ETHII-XXXX-XXXX-XXXX`) for the gated download service.
4. Operator downloads binaries:
   - `https://www.ethii.net/dl/ethii-linux-amd64?key=YOUR-KEY`
   - `https://www.ethii.net/dl/ethii-windows-amd64.exe?key=YOUR-KEY`
   - `https://www.ethii.net/dl/stratum-linux-amd64?key=YOUR-KEY`
   - `https://www.ethii.net/dl/stratum-windows-amd64.exe?key=YOUR-KEY`
5. Operator performs startup check-in.
6. Admin validates chain identity and marks operator `active`.

## Required startup identity

- net_version = `20482`
- eth_chainId = `0x800`
- genesis = `0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf`

## Status model

- `approved`: invited, not yet validated
- `active`: validated and allowed
- `paused`: temporarily disabled
- `blocked`: intentionally denied
- `quarantine`: chain mismatch or suspicious behavior

## Incident response

If chain health anomaly occurs:

1. Pause new approvals.
2. Stop stratum if chain integrity is uncertain.
3. Verify canonical chain identity on primary and secondary.
4. Keep only trusted/static peers while diagnosing.
5. Quarantine any operator with mismatched identity.
