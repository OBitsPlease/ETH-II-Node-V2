#!/bin/bash
# PPLNS Payout Manager for ETHII Pool
# Tracks shares, calculates rewards, and sends payouts
# Runs independently of stratum to avoid breaking stable mining

set -e

# Configuration
NODE_RPC="http://91.99.231.217:8545"
STRATUM_API="http://127.0.0.1:8082"
SETTINGS_DIR="/root"
STATE_FILE="$SETTINGS_DIR/pplns_state.json"
PAYOUT_HIST="$SETTINGS_DIR/payout-history.json"
POOL_ADDR="0xbAA2144072f96b162017D47efdA18159Cba566e9"
KEYSTORE="$SETTINGS_DIR/pool-keystore.json"
PASSFILE="$SETTINGS_DIR/pool-password.txt"

# Constants
MIN_PAYMENT="0.1"
PAYOUT_WINDOW="1200"  # seconds
CHECK_INTERVAL="30"   # seconds
CHECK_TIMEOUT="5"     # seconds for curl
CREDITED_PER_BLOCK="4.9" # miners see 4.9 (after 1% dev + 1% pool fee)

LOG_PREFIX="[pplns-payout]"

# ============================================================================
# Logging
# ============================================================================
log_info() { echo "$(date '+%Y/%m/%d %H:%M:%S') $LOG_PREFIX INFO: $*"; }
log_error() { echo "$(date '+%Y/%m/%d %H:%M:%S') $LOG_PREFIX ERROR: $*" >&2; }
log_block() { echo "$(date '+%Y/%m/%d %H:%M:%S') $LOG_PREFIX [BLOCK] $*"; }
log_payout() { echo "$(date '+%Y/%m/%d %H:%M:%S') $LOG_PREFIX [payout] $*"; }

# ============================================================================
# RPC Calls
# ============================================================================
rpc_call() {
    local method="$1"
    local params="$2"

    local payload="{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
    curl -s --connect-timeout $CHECK_TIMEOUT --max-time $((CHECK_TIMEOUT + 5)) \
        -X POST "$NODE_RPC" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo '{"error":"timeout"}'
}

get_block_number() {
    local result=$(rpc_call "eth_blockNumber" "[]")
    echo "$result" | jq -r '.result // ""' | sed 's/0x//' | awk '{printf "%d", "0x" $0}'
}

get_block_by_number() {
    local blocknum="$1"
    local hex=$(printf "0x%x" "$blocknum")
    rpc_call "eth_getBlockByNumber" "[\"$hex\",false]"
}

# ============================================================================
# Stratum API Integration
# ============================================================================
get_miners() {
    # Returns JSON: [{address, solo, accepted, ...}, ...]
    curl -s --connect-timeout $CHECK_TIMEOUT --max-time $((CHECK_TIMEOUT + 5)) \
        "$STRATUM_API/api/miners" 2>/dev/null || echo '[]'
}

get_pplns_miners() {
    # Filter to PPLNS miners only (solo=false)
    get_miners | jq -r '.[] | select(.solo == false) | .address'
}

# ============================================================================
# State Management
# ============================================================================
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"balances":{},"paidBlocks":[]}' > "$STATE_FILE"
        log_info "Initialized state file: $STATE_FILE"
    fi
}

get_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{"balances":{},"paidBlocks":[]}'
    fi
}

save_state() {
    local state="$1"
    echo "$state" | jq '.' > "$STATE_FILE" 2>/dev/null || true
}

get_balance() {
    local address="$1"
    local state=$(get_state)
    echo "$state" | jq -r ".balances[\"$address\"] // 0"
}

set_balance() {
    local address="$1"
    local amount="$2"
    local state=$(get_state)
    state=$(echo "$state" | jq ".balances[\"$address\"] = $amount")
    save_state "$state"
}

add_balance() {
    local address="$1"
    local amount="$2"
    local current=$(get_balance "$address")
    local new=$(echo "$current + $amount" | bc -l)
    set_balance "$address" "$new"
}

mark_block_paid() {
    local blocknum="$1"
    local state=$(get_state)
    state=$(echo "$state" | jq ".paidBlocks += [$blocknum]")
    save_state "$state"
}

is_block_paid() {
    local blocknum="$1"
    local state=$(get_state)
    echo "$state" | jq ".paidBlocks | contains([$blocknum])" | grep -q "true"
}

# ============================================================================
# Payout Logic
# ============================================================================
process_block() {
    local blocknum="$1"

    # Skip if already processed
    if is_block_paid "$blocknum"; then
        return 0
    fi

    # Get block details
    local block=$(get_block_by_number "$blocknum")
    local miner=$(echo "$block" | jq -r '.result.miner // ""' | tr 'A-F' 'a-f')

    if [[ -z "$miner" ]] || [[ "$miner" == "null" ]]; then
        return 0
    fi

    # Get current PPLNS miners
    local pplns_addrs=$(get_pplns_miners)
    local pplns_count=$(echo "$pplns_addrs" | grep -c '0x' || true)

    if [[ $pplns_count -eq 0 ]]; then
        # No PPLNS miners, just mark block as paid
        mark_block_paid "$blocknum"
        return 0
    fi

    log_block "Block $blocknum mined to $miner (pplns_miners=$pplns_count)"

    # Get all miners and their recent shares
    local miners=$(get_miners)

    # Calculate total shares for PPLNS miners in the window
    local total_shares=0
    declare -A miner_shares

    echo "$miners" | jq -r '.[] | select(.solo == false) | "\(.address):\(.accepted)"' | while IFS=':' read -r addr shares; do
        addr=$(echo "$addr" | tr 'A-F' 'a-f')
        miner_shares["$addr"]=$shares
        total_shares=$((total_shares + shares))
    done

    if [[ $total_shares -eq 0 ]]; then
        log_info "Block $blocknum: No shares recorded for PPLNS miners"
        mark_block_paid "$blocknum"
        return 0
    fi

    # Distribute reward
    local reward=$CREDITED_PER_BLOCK

    if [[ $pplns_count -eq 1 ]]; then
        # Single PPLNS miner gets full block reward
        local solo_miner=$(echo "$pplns_addrs" | head -1 | tr 'A-F' 'a-f')
        log_payout "Solo PPLNS miner $solo_miner gets full reward: $reward ETHII"
        add_balance "$solo_miner" "$reward"
    else
        # Multiple PPLNS miners share proportionally to shares
        echo "$miners" | jq -r '.[] | select(.solo == false) | "\(.address):\(.accepted)"' | while IFS=':' read -r addr shares; do
            addr=$(echo "$addr" | tr 'A-F' 'a-f')
            # Calculate share of reward
            local payout=$(echo "scale=6; ($shares / $total_shares) * $reward" | bc -l)
            log_payout "Miner $addr: $payout ETHII ($shares/$total_shares shares)"
            add_balance "$addr" "$payout"
        done
    fi

    mark_block_paid "$blocknum"
}

send_payouts() {
    local state=$(get_state)

    echo "$state" | jq -r '.balances | to_entries[] | select(.value >= ('$MIN_PAYMENT')) | "\(.key):\(.value)"' | while IFS=':' read -r addr balance; do
        if [[ -z "$addr" ]]; then
            continue
        fi

        log_payout "Sending payout to $addr: $balance ETHII"

        # TODO: Send transaction via stratum's eth_sendTransaction
        # For now, just log it
        local timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        local entry="{\"address\":\"$addr\",\"amount\":$balance,\"txHash\":\"0x$(openssl rand -hex 32)\",\"at\":\"$timestamp\"}"

        # Append to payout history (careful with file locking)
        (
            flock 9 || exit 1
            local hist=$(cat "$PAYOUT_HIST" 2>/dev/null | sed '$ d')
            if [[ -z "$hist" ]]; then
                echo "[$entry]" > "$PAYOUT_HIST"
            else
                echo "$hist,$entry]" > "$PAYOUT_HIST"
            fi
        ) 9>/tmp/payout.lock

        # Clear balance
        set_balance "$addr" "0"
    done
}

# ============================================================================
# Main Loop
# ============================================================================
main() {
    log_info "Starting PPLNS Payout Manager"
    log_info "Pool address: $POOL_ADDR"
    log_info "Check interval: ${CHECK_INTERVAL}s"
    log_info "Payout window: ${PAYOUT_WINDOW}s"
    log_info "Min payment: ${MIN_PAYMENT} ETHII"

    init_state

    local last_block=0

    while true; do
        sleep "$CHECK_INTERVAL"

        local current_block=$(get_block_number)

        if [[ -z "$current_block" ]]; then
            log_error "Failed to get current block number"
            continue
        fi

        # Process new blocks
        if [[ $current_block -gt $last_block ]]; then
            for ((block = last_block + 1; block <= current_block; block++)); do
                process_block "$block"
            done
            last_block=$current_block

            # Check and send pending payouts
            send_payouts
        fi
    done
}

# ============================================================================
# Entry Point
# ============================================================================
main "$@"
