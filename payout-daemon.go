package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Configuration
const (
	nodRPC            = "http://91.99.231.217:8545"
	dashboardAddr     = "http://127.0.0.1:8082"
	checkInterval     = 30 * time.Second
	pplnsWindow       = 1200 // seconds
	minPayment        = 0.1  // ETHII
	blockReward       = 5.0  // ETHII
	devFeePercent     = 1.0  // taken by consensus
	poolFeePercent    = 1.0  // taken by pool (miners credited 4.9)
	creditedPerBlock  = 4.9  // what miners see credited
)

type Miner struct {
	Address string
	Shares  int64
	LastSeen time.Time
}

type BlockEvent struct {
	BlockNum    int64
	Timestamp   time.Time
	FinderAddr  string
	IsSolo      bool
}

var (
	settingsDir     = "/root"
	stateFile       = filepath.Join(settingsDir, "pplns_state.json")
	keystore        = filepath.Join(settingsDir, "pool-keystore.json")
	passfile        = filepath.Join(settingsDir, "pool-password.txt")
	payoutHistFile  = filepath.Join(settingsDir, "payout-history.json")
	poolAddr        = "0xbAA2144072f96b162017D47efdA18159Cba566e9"

	mu              sync.RWMutex
	shares          = make(map[string]int64) // address -> share count this window
	lastProcessed   int64 = 0
)

type PPLNSState struct {
	Balances   map[string]float64 `json:"balances"`
	PaidBlocks []int64            `json:"paidBlocks"`
}

func rpcCall(method string, params interface{}) (json.RawMessage, error) {
	body, _ := json.Marshal(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
		"id":      1,
	})
	resp, err := http.Post(nodRPC, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var r map[string]interface{}
	json.Unmarshal(data, &r)
	if errObj, ok := r["error"].(map[string]interface{}); ok {
		return nil, fmt.Errorf("rpc error: %v", errObj["message"])
	}
	result, _ := json.Marshal(r["result"])
	return result, nil
}

func getBlockByNumber(blockNum int64) (map[string]interface{}, error) {
	raw, err := rpcCall("eth_getBlockByNumber", []interface{}{fmt.Sprintf("0x%x", blockNum), false})
	if err != nil {
		return nil, err
	}
	var block map[string]interface{}
	json.Unmarshal(raw, &block)
	return block, nil
}

func getCurrentBlock() (int64, error) {
	raw, err := rpcCall("eth_blockNumber", []interface{}{})
	if err != nil {
		return 0, err
	}
	var hexStr string
	json.Unmarshal(raw, &hexStr)
	var num int64
	fmt.Sscanf(hexStr, "0x%x", &num)
	return num, nil
}

func getMiners() (map[string]bool, error) {
	resp, err := http.Get(dashboardAddr + "/api/miners")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var miners []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&miners)

	result := make(map[string]bool) // address -> isPPLNS
	for _, m := range miners {
		if addr, ok := m["address"].(string); ok {
			if solo, ok := m["solo"].(bool); ok {
				result[addr] = !solo // true if PPLNS
			}
		}
	}
	return result, nil
}

func recordShare(minerAddr string) {
	mu.Lock()
	shares[minerAddr]++
	mu.Unlock()
}

func processBlock(blockNum int64) error {
	block, err := getBlockByNumber(blockNum)
	if err != nil {
		return err
	}

	miners, err := getMiners()
	if err != nil {
		return err
	}

	// Count PPLNS miners
	pplnsMiners := 0
	for _, isPplns := range miners {
		if isPplns {
			pplnsMiners++
		}
	}

	if pplnsMiners == 0 {
		log.Printf("[pplns] Block %d: no PPLNS miners, skipping payout", blockNum)
		return nil
	}

	mu.RLock()
	sharesCopy := make(map[string]int64)
	for k, v := range shares {
		if isPplns, ok := miners[k]; ok && isPplns {
			sharesCopy[k] = v
		}
	}
	mu.RUnlock()

	totalShares := int64(0)
	for _, s := range sharesCopy {
		totalShares += s
	}

	if totalShares == 0 {
		log.Printf("[pplns] Block %d: no shares recorded", blockNum)
		return nil
	}

	// Reward = 4.9 ETHII (after dev fee and pool fee)
	reward := creditedPerBlock

	// Single PPLNS miner gets full block
	if pplnsMiners == 1 {
		for addr := range sharesCopy {
			log.Printf("[pplns] Block %d: Solo PPLNS miner %s gets full reward %.2f ETHII", blockNum, addr[:6], reward)
			queuePayout(addr, reward)
		}
	} else {
		// Multiple PPLNS miners share proportionally
		for addr, shares := range sharesCopy {
			payout := (float64(shares) / float64(totalShares)) * reward
			if payout >= minPayment {
				log.Printf("[pplns] Block %d: %s gets %.6f ETHII (%d/%d shares)", blockNum, addr[:6], payout, shares, totalShares)
				queuePayout(addr, payout)
			}
		}
	}

	// Reset shares for next window
	mu.Lock()
	shares = make(map[string]int64)
	mu.Unlock()

	return nil
}

func queuePayout(address string, amount float64) {
	// Load current state
	state := &PPLNSState{
		Balances:   make(map[string]float64),
		PaidBlocks: []int64{},
	}

	if data, err := os.ReadFile(stateFile); err == nil {
		json.Unmarshal(data, state)
	}

	// Add to balance
	state.Balances[address] += amount

	// Save state
	data, _ := json.MarshalIndent(state, "", "  ")
	os.WriteFile(stateFile, data, 0644)

	// If balance >= minPayment, send payout
	if state.Balances[address] >= minPayment {
		sendPayout(address, state.Balances[address])
		state.Balances[address] = 0
		data, _ := json.MarshalIndent(state, "", "  ")
		os.WriteFile(stateFile, data, 0644)
	}
}

func sendPayout(address string, amount float64) {
	weiAmount := big.NewFloat(amount).Mul(big.NewFloat(amount), big.NewFloat(1e18))
	weiInt := new(big.Int)
	weiAmount.Int(weiInt)

	txObj := map[string]interface{}{
		"from":     poolAddr,
		"to":       address,
		"value":    fmt.Sprintf("0x%x", weiInt),
		"gas":      "0x5208",
		"gasPrice": "0x1DCD6500",
	}

	raw, err := rpcCall("eth_sendTransaction", []interface{}{txObj})
	if err != nil {
		log.Printf("[payout] Failed to %s amount %.2f: %v", address[:6], amount, err)
		return
	}

	var txHash string
	json.Unmarshal(raw, &txHash)

	// Record in history
	entry := map[string]interface{}{
		"address": address,
		"amount":  amount,
		"txHash":  txHash,
		"at":      time.Now().Format(time.RFC3339Nano),
	}

	histFile, _ := os.ReadFile(payoutHistFile)
	var hist []interface{}
	if histFile != nil {
		json.Unmarshal(histFile[0:len(histFile)-1], &hist) // trim ]
	}
	hist = append(hist, entry)
	data, _ := json.MarshalIndent(hist, "", "  ")
	os.WriteFile(payoutHistFile, append(data, ']'), 0644)

	log.Printf("[payout] Sent %.2f ETHII to %s (tx: %s)", amount, address[:6], txHash)
}

func monitorLoop() {
	for {
		time.Sleep(checkInterval)

		currentBlock, err := getCurrentBlock()
		if err != nil {
			log.Printf("Error getting current block: %v", err)
			continue
		}

		if currentBlock > lastProcessed {
			for blockNum := lastProcessed + 1; blockNum <= currentBlock; blockNum++ {
				if err := processBlock(blockNum); err != nil {
					log.Printf("Error processing block %d: %v", blockNum, err)
				}
			}
			lastProcessed = currentBlock
		}
	}
}

func main() {
	log.SetPrefix("[pplns-daemon] ")
	log.Printf("Starting PPLNS payout daemon")
	log.Printf("Pool wallet: %s", poolAddr)
	log.Printf("Settings dir: %s", settingsDir)
	log.Printf("Check interval: %v", checkInterval)
	log.Printf("PPLNS window: %d seconds", pplnsWindow)
	log.Printf("Min payment: %.2f ETHII", minPayment)

	monitorLoop()
}
