# ETH II Multi-Pool Server Stack

Server-side components that run on the **EU truth host** (alongside the canonical
archive node) to support multiple independent mining pools with **on-chain reward
separation**: every pool's own wallet is the coinbase on the blocks it finds, with
no lag and no fork.

## Why this exists

ETH II is a post-merge Geth fork forced to pure PoW. Post-merge Geth removed P2P
block gossip (blocks used to arrive from the consensus layer). With a single shared
node, every pool's miners pulled the **same** work template, so all rewards landed
on one address and secondary pools lagged on stale jobs.

The fix has two halves:

1. **ETH71 gossip binary** (`/root/ethii`) ΓÇö re-adds P2P block propagation
   (`BroadcastBlock` / `handleNewBlock` / `NewBlockPacket`) so every pool's tenant
   node imports new blocks instantly. This eliminates lag.
2. **Per-pool tenant nodes** ΓÇö each pool gets its own lightweight tenant node whose
   `--miner.pending.feeRecipient` is that pool's wallet. A forkchoice driver arms
   each tenant to serve fresh `head+1` work paying its own address. Miners connect
   through a per-pool RPC **gate** that routes work to the tenant and reads to truth.

## Components

| File | Role |
|------|------|
| `serve.py` | Gated download + provisioning HTTP service (key-checked). Calls `provision.sh` / `peer-provision.sh`. |
| `provision.sh` | **Pool installer backend.** Creates a tenant node + RPC gate + `/opt/ethii-tenants/<wallet>.conf` (with `ARM=1`) for a new pool. Allocates non-colliding ports, inits from canonical genesis, starts services. |
| `peer-provision.sh` | **Node-only installer backend.** Provisions a non-mining relay peer (network support, no rewards). |
| `tenant-rpc-gate.py` | Per-pool RPC proxy. Routes `ethash_getWork`/`submitWork` to the pool's tenant; routes reads to truth. Blocks work while the tenant is desynced (`--lag-max`). |
| `ethii-fc-driver-v2.py` | Forkchoice driver. Keeps every tenant synced to truth's canonical head (lag fix) and, for tenants with `ARM=1`, arms fresh own-coinbase work via the engine API + `miner_start`. Auto-discovers new tenants every 30s. |
| `multipool-cutover.sh` | Phased, reversible cutover to reward separation. **Never restarts tenants** (they are armed live via RPC). Phase A = reward-neutral prep; Phase B = make truth relay-only. |
| `multipool-rollback.sh` | Restores the pre-cutover node unit, tenant confs, and binary. |

## Tenant conf format (`/opt/ethii-tenants/<wallet>.conf`)

```
RPC_PORT=8552            # external gate port miners connect to
INTERNAL_RPC_PORT=18552  # tenant geth http (localhost)
P2P_PORT=30310           # tenant devp2p
AUTHRPC_PORT=9557        # tenant engine API (driver arms via this)
IP=<operator source ip>  # firewall allow for the gate port
PORTS=<stratum ports>
KEY=<enrollment key>
ARM=1                    # 1 => fc-driver-v2 serves own-coinbase work (separation ON)
```

`ARM=1` is proven-safe: arming only builds the work template; it never CPU-seals.
A pool only produces blocks when its real miners submit valid work to its gate.

## Onboarding a new pool (e.g. CryptoSky)

1. Operator runs the pool installer with their wallet + enrollment key; `serve.py`
   invokes `provision.sh <wallet> <ip> <ports> <key>`.
2. `provision.sh` creates the tenant + gate (ARM=1) and returns the gate port.
3. `ethii-fc-driver-v2.py` auto-discovers the tenant within 30s and arms it.
4. Operator points their stratum `-node` at `http://<EU_IP>:<gate_port>`.
5. Their blocks now pay their own wallet on-chain.

## Reserved ports (never reused by the allocator)

`8545` truth HTTP, `8551` truth authrpc. The allocator in `provision.sh` skips
reserved + already-used + currently-bound ports.
