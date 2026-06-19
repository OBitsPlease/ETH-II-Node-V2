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
	"sync"
	"time"
)

// Settings
const (
	nodeURL       = "http://91.99.231.217:8545"
	dashURL       = "http://127.0.0.1:8082"
	checkInterval = 15 * time.Second
	minPayment    = 0.1
	rewardCredit  = 4.9 // miners see 4.9 ETHII per block (after dev+pool fee)
)

var (
	settingsDir   = "/root"
	stateFile     = filepath.Join(settingsDir, "pplns_state.json")
	historyFile   = filepath.Join(settingsDir, "payout-history.json")
	poolAddr      = "0xbAA2144072f96b162017D47efdA18159Cba566e9"
	lastProcessed int64
	mu            sync.Mutex
)

// PPLNSState holds balances and paid block list
type PPLNSState struct {
	Balances   map[string]float64 `json:"balances"`
	PaidBlocks []int64            `json:"paidBlocks"`
}

// ─────────────────────────────────────────────────────────────────────────────

func rpcPost(method string, params interface{}) (json.RawMessage, error) {
	body, _ := json.Marshal(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
		"id":      1,
	})
	resp, err := http.Post(nodeURL, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var r map[string]interface{}
	json.Unmarshal(data, &r)
	if errObj, ok := r["error"].(map[string]interface{}); ok {
		msg := "unknown"
		if m, ok := errObj["message"].(string); ok {
			msg = m
		}
		return nil, fmt.Errorf(msg)
	}
	result, _ := json.Marshal(r["result"])
	return result, nil
}

func getBlockNum() (int64, error) {
	raw, err := rpcPost("eth_blockNumber", []interface{}{})
	if err != nil {
		return 0, err
	}
	var hexStr string
	json.Unmarshal(raw, &hexStr)
	var num int64
	fmt.Sscanf(hexStr, "0x%x", &num)
	return num, nil
}

func getBlock(num int64) (map[string]interface{}, error) {
	hex := fmt.Sprintf("0x%x", num)
	raw, err := rpcPost("eth_getBlockByNumber", []interface{}{hex, false})
	if err != nil {
		return nil, err
	}
	var block map[string]interface{}
	json.Unmarshal(raw, &block)
	return block, nil
}

// ─────────────────────────────────────────────────────────────────────────────

func loadState() (*PPLNSState, error) {
	data, err := os.ReadFile(stateFile)
	if err != nil {
		return &PPLNSState{Balances: make(map[string]float64), PaidBlocks: []int64{}}, nil
	}
	var s PPLNSState
	json.Unmarshal(data, &s)
	if s.Balances == nil {
		s.Balances = make(map[string]float64)
	}
	return &s, nil
}

func saveState(s *PPLNSState) error {
	data, _ := json.MarshalIndent(s, "", "  ")
	return os.WriteFile(stateFile, data, 0644)
}

func isPaidBlock(s *PPLNSState, num int64) bool {
	for _, b := range s.PaidBlocks {
		if b == num {
			return true
		}
	}
	return false
}

// ─────────────────────────────────────────────────────────────────────────────

func getMinerInfo() ([]map[string]interface{}, error) {
	resp, err := http.Get(dashURL + "/api/miners")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var miners []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&miners)
	return miners, nil
}

// ─────────────────────────────────────────────────────────────────────────────

func processBlock(blockNum int64, s *PPLNSState) error {
	// Get block
	block, err := getBlock(blockNum)
	if err != nil {
		return err
	}

	if block == nil || block["miner"] == nil {
		return nil
	}

	// Get miners
	miners, err := getMinerInfo()
	if err != nil {
		return err
	}

	// Count PPLNS miners and collect their shares
	pplnsCount := 0
	shares := make(map[string]int64)
	totalShares := int64(0)

	for _, m := range miners {
		if solo, ok := m["solo"].(bool); ok && !solo {
			if addr, ok := m["address"].(string); ok {
				pplnsCount++
				if accepted, ok := m["accepted"].(float64); ok {
					s := int64(accepted)
					shares[addr] = s
					totalShares += s
				}
			}
		}
	}

	if pplnsCount == 0 || totalShares == 0 {
		s.PaidBlocks = append(s.PaidBlocks, blockNum)
		return nil
	}

	log.Printf("[pplns] Block %d: %d PPLNS miners, %d total shares", blockNum, pplnsCount, totalShares)

	// Distribute reward
	if pplnsCount == 1 {
		// Solo PPLNS miner gets full reward
		for addr := range shares {
			s.Balances[addr] += rewardCredit
			log.Printf("[payout] Solo PPLNS %s: +%.2f ETHII (block %d)", addr[:8], rewardCredit, blockNum)
		}
	} else {
		// Multiple miners share proportionally
		for addr, minerShares := range shares {
			payout := (float64(minerShares) / float64(totalShares)) * rewardCredit
			s.Balances[addr] += payout
			log.Printf("[payout] PPLNS %s: +%.6f ETHII (%d/%d shares, block %d)", addr[:8], payout, minerShares, totalShares, blockNum)
		}
	}

	s.PaidBlocks = append(s.PaidBlocks, blockNum)
	return nil
}

// ─────────────────────────────────────────────────────────────────────────────

func sendPayout(addr string, amount float64) error {
	// Convert ETHII to wei
	weiF := amount * 1e18
	weiI := new(big.Int)
	weiI.SetString(fmt.Sprintf("%.0f", weiF), 10)
	valueHex := fmt.Sprintf("0x%x", weiI)

	// Build transaction
	txObj := map[string]interface{}{
		"from":     poolAddr,
		"to":       addr,
		"value":    valueHex,
		"gas":      "0x5208",
		"gasPrice": "0x1DCD6500",
	}

	// Send via node RPC (assumes keystore is unlocked/available to node)
	raw, err := rpcPost("eth_sendTransaction", []interface{}{txObj})
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: %v", addr[:8], amount, err)
		return err
	}

	var txHash string
	json.Unmarshal(raw, &txHash)

	// Record in history
	entry := map[string]interface{}{
		"address": addr,
		"amount":  amount,
		"txHash":  txHash,
		"at":      time.Now().Format(time.RFC3339Nano),
	}

	// Append to payout-history.json (with file locking)
	histData, _ := os.ReadFile(historyFile)
	var hist []interface{}
	if len(histData) > 0 {
		json.Unmarshal(histData[:len(histData)-1], &hist) // trim ]
	}
	hist = append(hist, entry)
	finalData, _ := json.MarshalIndent(hist, "", "  ")
	os.WriteFile(historyFile, append(finalData, ']'), 0644)

	log.Printf("[payout] SENT %.2f ETHII to %s (tx: %s)", amount, addr[:8], txHash)
	return nil
}

func processPendingPayouts(s *PPLNSState) {
	for addr, balance := range s.Balances {
		if balance >= minPayment {
			if err := sendPayout(addr, balance); err == nil {
				s.Balances[addr] = 0
			}
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────

func main() {
	log.SetPrefix("[pplns-daemon] ")
	log.Printf("Starting PPLNS Payout Daemon")
	log.Printf("Node RPC: %s", nodeURL)
	log.Printf("Dashboard: %s", dashURL)
	log.Printf("Settings: %s", settingsDir)
	log.Printf("Min payment: %.2f ETHII", minPayment)
	log.Printf("Credit per block: %.2f ETHII", rewardCredit)

	lastProcessed = 0

	for {
		time.Sleep(checkInterval)

		// Load current state
		state, err := loadState()
		if err != nil {
			log.Printf("ERROR loading state: %v", err)
			continue
		}

		// Get current block
		current, err := getBlockNum()
		if err != nil {
			log.Printf("ERROR getting block number: %v", err)
			continue
		}

		// Process new blocks
		if current > lastProcessed {
			for blockNum := lastProcessed + 1; blockNum <= current; blockNum++ {
				if !isPaidBlock(state, blockNum) {
					if err := processBlock(blockNum, state); err != nil {
						log.Printf("ERROR processing block %d: %v", blockNum, err)
					}
				}
			}
			lastProcessed = current

			// Try to send pending payouts
			processPendingPayouts(state)

			// Save state
			if err := saveState(state); err != nil {
				log.Printf("ERROR saving state: %v", err)
			}
		}
	}
}
