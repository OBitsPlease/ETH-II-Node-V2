package main

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/hex"
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

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

const (
	nodeURL       = "http://91.99.231.217:8545"
	dashURL       = "http://127.0.0.1:8082"
	checkInterval = 15 * time.Second
	minPayment    = 0.1
	rewardCredit  = 4.9
	chainID       = 20482
)

var (
	settingsDir      = "/root"
	stateFile        = filepath.Join(settingsDir, "pplns_state.json")
	historyFile      = filepath.Join(settingsDir, "payout-history.json")
	blockFindersFile = filepath.Join(settingsDir, "block-finders.json")
	poolAddr         = common.HexToAddress("0xbAA2144072f96b162017D47efdA18159Cba566e9")
	privateKey       *ecdsa.PrivateKey
	lastProcessed    int64
	stateMu          sync.Mutex
	balances         = make(map[string]float64)
	paidBlocks       = make(map[int64]bool)
)

type PPLNSState struct {
	Balances   map[string]float64 `json:"balances"`
	PaidBlocks []int64            `json:"paidBlocks"`
}

type BlockFinder struct {
	Block     int64  `json:"block"`
	Address   string `json:"address"`
	Worker    string `json:"worker"`
	Solo      bool   `json:"solo"`
	Timestamp string `json:"at"`
}

func init() {
	privKeyHex := "4598c32486829415ba0230b8439678fb2b9181a4d008d4a49d77f9397362fa99"
	pk, err := crypto.HexToECDSA(privKeyHex)
	if err != nil {
		log.Fatalf("Failed to load private key: %v", err)
	}
	privateKey = pk
}

func rpcCall(method string, params interface{}) (json.RawMessage, error) {
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

func getBlock(num int64) (map[string]interface{}, error) {
	hex := fmt.Sprintf("0x%x", num)
	raw, err := rpcCall("eth_getBlockByNumber", []interface{}{hex, false})
	if err != nil {
		return nil, err
	}
	var block map[string]interface{}
	json.Unmarshal(raw, &block)
	return block, nil
}

func getNonce(addr common.Address) (uint64, error) {
	raw, err := rpcCall("eth_getTransactionCount", []interface{}{addr.Hex(), "pending"})
	if err != nil {
		return 0, err
	}
	var hexStr string
	json.Unmarshal(raw, &hexStr)
	var nonce uint64
	fmt.Sscanf(hexStr, "0x%x", &nonce)
	return nonce, nil
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

func getBlockFinder(blockNum int64) *BlockFinder {
	data, err := os.ReadFile(blockFindersFile)
	if err != nil {
		return nil
	}
	var blocks []BlockFinder
	if err := json.Unmarshal(data, &blocks); err != nil {
		return nil
	}
	for _, b := range blocks {
		if b.Block == blockNum {
			return &b
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

	// Check block-finders.json for who found this block
	blockFound := getBlockFinder(blockNum)
	if blockFound != nil {
		minerAddr := common.HexToAddress(blockFound.Address)
		log.Printf("[block] Block %d: Found by %s - queueing payout %.2f ETHII", blockNum, blockFound.Address[:10], rewardCredit)

		stateMu.Lock()
		balances[blockFound.Address] += rewardCredit
		paidBlocks[blockNum] = true
		stateMu.Unlock()

		// Immediately try to send if balance >= minPayment
		if balances[blockFound.Address] >= minPayment {
			if err := sendPayout(minerAddr, balances[blockFound.Address]); err == nil {
				stateMu.Lock()
				balances[blockFound.Address] = 0
				stateMu.Unlock()
			}
		}
		return nil
	}

	stateMu.Lock()
	paidBlocks[blockNum] = true
	stateMu.Unlock()
	return nil
}

func sendPayout(toAddr common.Address, amount float64) error {
	nonce, err := getNonce(poolAddr)
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: failed to get nonce: %v", toAddr.Hex()[:10], amount, err)
		return err
	}

	time.Sleep(200 * time.Millisecond)

	weiAmount := new(big.Float).Mul(big.NewFloat(amount), big.NewFloat(1e18))
	weiInt := new(big.Int)
	weiAmount.Int(weiInt)

	gasPrice := new(big.Int)
	gasPrice.SetString("20000000000", 10) // 20 Gwei

	tx := types.NewTransaction(
		nonce,
		toAddr,
		weiInt,
		21000,
		gasPrice,
		nil,
	)

	signer := types.NewEIP155Signer(big.NewInt(chainID))
	signedTx, err := types.SignTx(tx, signer, privateKey)
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: signing failed: %v", toAddr.Hex()[:10], amount, err)
		return err
	}

	txData, err := signedTx.MarshalBinary()
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: marshal failed: %v", toAddr.Hex()[:10], amount, err)
		return err
	}

	rawTx := "0x" + hex.EncodeToString(txData)
	raw, err := rpcCall("eth_sendRawTransaction", []interface{}{rawTx})
	if err != nil {
		log.Printf("[payout] FAIL %s %.2f ETHII: %v", toAddr.Hex()[:10], amount, err)
		return err
	}

	var txHash string
	json.Unmarshal(raw, &txHash)

	entry := map[string]interface{}{
		"address": toAddr.Hex(),
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

	log.Printf("[payout] SENT %.2f ETHII to %s (tx: %s)", amount, toAddr.Hex()[:10], txHash)
	return nil
}

func main() {
	log.SetPrefix("[payout] ")
	log.Printf("Starting PPLNS Payout Daemon with Local Signing")
	log.Printf("Pool Address: %s", poolAddr.Hex())
	log.Printf("Node RPC: %s", nodeURL)

	if err := loadState(); err != nil {
		log.Printf("WARNING loading state: %v", err)
	}

	current, err := getBlockNum()
	if err != nil {
		log.Printf("ERROR getting initial block: %v", err)
		lastProcessed = 0
	} else {
		stateMu.Lock()
		maxPaidBlock := int64(0)
		for b := range paidBlocks {
			if b > maxPaidBlock {
				maxPaidBlock = b
			}
		}
		stateMu.Unlock()

		if maxPaidBlock > 0 {
			lastProcessed = maxPaidBlock
		} else {
			lastProcessed = current - 100
		}
		log.Printf("Initialized to block %d (current: %d)", lastProcessed, current)
	}

	for {
		time.Sleep(checkInterval)

		current, err := getBlockNum()
		if err != nil {
			log.Printf("ERROR getting block number: %v", err)
			continue
		}

		if current > lastProcessed {
			log.Printf("[loop] Processing blocks %d-%d", lastProcessed+1, current)
			for blockNum := lastProcessed + 1; blockNum <= current; blockNum++ {
				if err := processBlock(blockNum); err != nil {
					log.Printf("ERROR processing block %d: %v", blockNum, err)
				}
			}
			lastProcessed = current
			log.Printf("[loop] Completed batch, now at block %d", lastProcessed)

			if err := saveState(); err != nil {
				log.Printf("ERROR saving state: %v", err)
			}
		}
	}
}
