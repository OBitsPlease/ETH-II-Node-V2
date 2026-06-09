# ETH-II Controlled Operator Policy

## Goal

Keep chain participation open enough for growth while reducing unknown-risk operators.

## Distribution model

- Public repo: docs/templates only
- Controlled binaries: distributed only to approved operators

## Approval flow

1. Operator submits Access Request.
2. Admin assigns Operator ID (`OP-XXXX`).
3. Admin distributes approved binaries privately.
4. Operator performs startup check-in.
5. Admin validates chain identity and marks operator `active`.

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
