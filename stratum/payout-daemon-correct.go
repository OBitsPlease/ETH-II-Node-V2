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

const (
	nodeURL       = "http://91.99.231.217:8545"
	dashURL       = "http://127.0.0.1:8082"
	checkInterval = 15 * time.Second
	minPayment    = 0.1
	rewardCredit  = 4.9
)

var (
	settingsDir   = "/root"
	stateFile     = filepath.Join(settingsDir, "pplns_state.json")
	historyFile   = filepath.Join(settingsDir, "payout-history.json")
	poolAddr      = "0xbAA2144072f96b162017D47efdA18159Cba566e9"
	lastProcessed int64
	stateMu       sync.Mutex
	balances      = make(map[string]float64)
	paidBlocks    = make(map[int64]bool)
)

type PPLNSState struct {
	Balances   map[string]float64 `json:"balances"`
	PaidBlocks []int64            `json:"paidBlocks"`
}

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

func loadState() error {
	stateMu.Lock()
	defer stateMu.Unlock()

	data, err := os.ReadFile(stateFile)
	if err != nil {
		return nil
	}

	var s PPLNSState
	if err := json.Unmarshal(data, &s); err != nil {
		log.Printf("ERROR parsing state file: %v", err)
		return err
	}

	balances = s.Balances
	if balances == nil {
		balances = make(map[string]float64)
	}

	paidBlocks = make(map[int64]bool)
	for _, b := range s.PaidBlocks {
		paidBlocks[b] = true
	}

	log.Printf("Loaded state: %d balances, %d paid blocks", len(balances), len(paidBlocks))
	return nil
}

func saveState() error {
	stateMu.Lock()
	defer stateMu.Unlock()

	paidBlocksList := make([]int64, 0, len(paidBlocks))
	for b := range paidBlocks {
		paidBlocksList = append(paidBlocksList, b)
	}

	s := PPLNSState{
		Balances:   balances,
		PaidBlocks: paidBlocksList,
	}

	data, _ := json.MarshalIndent(s, "", "  ")
	if err := os.WriteFile(stateFile, data, 0644); err != nil {
		log.Printf("ERROR saving state: %v", err)
		return err
	}
	return nil
}

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

func getBlockFinder(blockNum int64) map[string]interface{} {
	data, err := os.ReadFile("/root/block-finders.json")
	if err != nil {
		return nil
	}
	var blocks []map[string]interface{}
	if err := json.Unmarshal(data, &blocks); err != nil {
		return nil
	}
	for _, b := range blocks {
		if bNum, ok := b["block"].(float64); ok && int64(bNum) == blockNum {
			return b
		}
	}
	return nil
}

func processBlock(blockNum int64) error {
	stateMu.Lock()
	if _, alreadyPaid := paidBlocks[blockNum]; alreadyPaid {
		stateMu.Unlock()
		return nil
	}
	stateMu.Unlock()

	block, err := getBlock(blockNum)
	if err != nil {
		return err
	}

	if block == nil || block["miner"] == nil {
		return nil
	}

	// Check block-finders.json for who actually found this block
	blockFound := getBlockFinder(blockNum)
	if blockFound != nil {
		minerAddr, ok := blockFound["address"].(string)
		if !ok {
			return nil
		}
		log.Printf("[block] Block %d: Found by %s - sending payout %.2f ETHII", blockNum, minerAddr[:8], rewardCredit)
		sendPayout(minerAddr, rewardCredit)
		stateMu.Lock()
		paidBlocks[blockNum] = true
		stateMu.Unlock()
		return nil
	}

	stateMu.Lock()
	paidBlocks[blockNum] = true
	stateMu.Unlock()
	return nil
}

func sendPayout(addr string, amount float64) error {
	weiF := amount * 1e18
	weiI := new(big.Int)
	weiI.SetString(fmt.Sprintf("%.0f", weiF), 10)
	valueHex := fmt.Sprintf("0x%x", weiI)

	txObj := map[string]interface{}{
		"from":     poolAddr,
		"to":       addr,
		"value":    valueHex,
		"gas":      "0x5208",
		"gasPrice": "0x1DCD6500",
	}

	raw, err := rpcPost("eth_sendTransaction", []interface{}{txObj})
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: %v", addr[:8], amount, err)
		return err
	}

	var txHash string
	json.Unmarshal(raw, &txHash)

	entry := map[string]interface{}{
		"address": addr,
		"amount":  amount,
		"txHash":  txHash,
		"at":      time.Now().Format(time.RFC3339Nano),
	}

	histData, _ := os.ReadFile(historyFile)
	var hist []interface{}
	if len(histData) > 0 {
		json.Unmarshal(histData[:len(histData)-1], &hist)
	}
	hist = append(hist, entry)
	finalData, _ := json.MarshalIndent(hist, "", "  ")
	os.WriteFile(historyFile, append(finalData, ']'), 0644)

	log.Printf("[payout] SENT %.2f ETHII to %s (tx: %s)", amount, addr[:8], txHash)
	return nil
}

func processPendingPayouts() {
	stateMu.Lock()
	defer stateMu.Unlock()

	for addr, balance := range balances {
		if balance >= minPayment {
			if err := sendPayout(addr, balance); err == nil {
				balances[addr] = 0
			}
		}
	}
}

func main() {
	log.SetPrefix("[pplns-daemon] ")
	log.Printf("Starting PPLNS Payout Daemon - CORRECT LOGIC")
	log.Printf("Node RPC: %s", nodeURL)
	log.Printf("Dashboard: %s", dashURL)

	if err := loadState(); err != nil {
		log.Printf("WARNING loading state: %v", err)
	}

	current, err := getBlockNum()
	if err != nil {
		log.Printf("ERROR getting initial block number: %v", err)
		lastProcessed = 0
	} else {
		lastProcessed = current
		log.Printf("Initialized to block %d", lastProcessed)
	}

	for {
		time.Sleep(checkInterval)

		current, err := getBlockNum()
		if err != nil {
			log.Printf("ERROR getting block number: %v", err)
			continue
		}

		if current > lastProcessed {
			for blockNum := lastProcessed + 1; blockNum <= current; blockNum++ {
				if err := processBlock(blockNum); err != nil {
					log.Printf("ERROR processing block %d: %v", blockNum, err)
				}
			}
			lastProcessed = current

			processPendingPayouts()

			if err := saveState(); err != nil {
				log.Printf("ERROR saving state: %v", err)
			}
		}
	}
}
