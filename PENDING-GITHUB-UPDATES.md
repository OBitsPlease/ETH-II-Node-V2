# Pending GitHub Updates

This file tracks changes made since the last push.

## Tracked In Current Git Repo (ready to commit here)

1. stratum/main.go
- Added chain explorer API endpoints used by website pages (`/api/chain/info`, blocks, block-by-hash, tx, address).
- Added block pagination support (`offset`) for explorer use.
- Added ASIC hashrate estimation fields and source flags in `/api/miners`.
- Added worker label support in miner API payload for display overrides.
- Fixed RPC request `params` handling to always send array (`[]`) instead of `null`.

2. wallet/launch-node.ps1
- Added automatic firewall rule creation for selected dynamic P2P port (TCP + UDP) to improve peer connectivity.

3. watchdog-autopilot.ps1
- Added explicit bootnode configuration for node restarts.
- Added `--bootnodes` and `--maxpeers 100` to restart arguments.

## Website Changes Applied On VPS (not tracked in this repo)

These were updated directly on `/var/www/ethii` and need to be mirrored into the website source repo/worktree before GitHub push:

1. index.html (live VPS variant)
- Fixed resource/tool cards to be real clickable links.
- Set working links for Block Explorer, Pool Dashboard, Documentation, GitHub Repos, Mining Guides.
- Kept Community Discord as placeholder link.
- Fixed hero CTA buttons:
  - `START MINING` now scrolls to `#section-4`.
  - `LEARN MORE` now scrolls to `#section-2`.

2. pool.html
- Updated top nav wording/links to match original homepage button set (`Hero/Why/Stats/Mine/Explore/Chain`).
- Updated footer `3D Visualizer` link to point to main visualizer section (`index.html#section-6`) instead of standalone page.
- Added Peer Health panel:
  - Connected peers
  - Last non-zero peer time
  - Status (`Connected` / `Intermittent` / `Isolated`)

3. explorer.html
- Updated top nav wording/links to match original homepage button set.
- Updated footer `3D Visualizer` link to point to main visualizer section (`index.html#section-6`).
- Fixed search behavior for 64-char hashes (block-hash lookup first).
- Added block list pagination support with `offset`.
- Added Peer Health status (with last non-zero tracking).

4. visualizer.html
- Replaced standalone visualizer page with an immediate redirect to `index.html#section-6`.
- This removes the duplicate/non-working 3D destination while preserving backward compatibility for old links.

## Notes

- Current local git status in this repo: `stratum/main.go`, `wallet/launch-node.ps1`, `watchdog-autopilot.ps1`.
- Website files may live in a separate Git repository/worktree from this root; mirror VPS edits there before final website GitHub push.
