package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ─── Config ──────────────────────────────────────────────────────────────────

// ─── Dev fee (hardcoded, not configurable) ────────────────────────────────────
// 1% of every block reward is permanently allocated to the ETHII developer.
// This is enforced at the consensus layer (node binary) and displayed here.
const (
	devFeeAddress = "0xEd383d14dfAd55dd31acB39100a4af12aFAE1911"
	devFeePercent = 1.0
)

var (
	nodeURL        = flag.String("node", "http://127.0.0.1:8545", "ETHII node RPC URL")
	stratumAddr    = flag.String("stratum", "0.0.0.0:3333", "Stratum listen address")
	a10StratumAddr = flag.String("a10-stratum", "0.0.0.0:3336", "Optional Innosilicon A10 compatibility stratum address (empty disables)")
	a10NotifyOrder = flag.String("a10-notify-order", "job-header-seed", "A10 notify order: job-header-seed or job-seed-header")
	a10Difficulty  = flag.Float64("a10-difficulty", 1.0, "A10 static mining.set_difficulty value")
	dashboardAddr  = flag.String("dashboard", "0.0.0.0:8082", "Dashboard HTTP address (empty = disabled)")
	workInterval   = flag.Duration("interval", 2*time.Second, "Work refresh interval")
	settingsDir    = flag.String("settings", ".", "Directory for settings persistence files")
	etherbaseFlag  = flag.String("etherbase", "", "Mining reward address (skip eth_coinbase lookup)")
)

type stratumMode int

const (
	modeStandard stratumMode = iota
	modeA10Compat
)

// ─── RPC helpers ─────────────────────────────────────────────────────────────

type rpcRequest struct {
	JSONRPC string        `json:"jsonrpc"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
	ID      int           `json:"id"`
}

type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

var rpcHTTPClient = &http.Client{
	Timeout: 6 * time.Second,
	Transport: &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   3 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		MaxIdleConns:        64,
		MaxIdleConnsPerHost: 32,
		MaxConnsPerHost:     64,
		IdleConnTimeout:     30 * time.Second,
	},
}

func rpcCall(method string, params []interface{}) (json.RawMessage, error) {
	if params == nil {
		params = []interface{}{}
	}
	body, _ := json.Marshal(rpcRequest{JSONRPC: "2.0", Method: method, Params: params, ID: 1})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, *nodeURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := rpcHTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var r rpcResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, err
	}
	if r.Error != nil {
		return nil, fmt.Errorf("rpc error: %s", r.Error.Message)
	}
	return r.Result, nil
}

// getWork returns [headerHash, seedHash, target, blockNumber]
func getWork() ([4]string, error) {
	raw, err := rpcCall("ethash_getWork", nil)
	if err != nil {
		return [4]string{}, err
	}
	var result [4]string
	if err := json.Unmarshal(raw, &result); err != nil {
		return [4]string{}, err
	}
	return result, nil
}

func submitWork(nonce, header, mix string) (bool, error) {
	raw, err := rpcCall("ethash_submitWork", []interface{}{nonce, header, mix})
	if err != nil {
		return false, err
	}
	var ok bool
	json.Unmarshal(raw, &ok)
	return ok, nil
}

// ─── Work broadcaster ────────────────────────────────────────────────────────

type WorkUpdate struct {
	HeaderHash string
	SeedHash   string
	Target     string
	Height     string
}

type WorkBroadcaster struct {
	mu          sync.RWMutex
	current     WorkUpdate
	subscribers map[int64]chan WorkUpdate
	nextID      int64
}

func newWorkBroadcaster() *WorkBroadcaster {
	return &WorkBroadcaster{subscribers: make(map[int64]chan WorkUpdate)}
}

func (wb *WorkBroadcaster) subscribe() (int64, chan WorkUpdate) {
	id := atomic.AddInt64(&wb.nextID, 1)
	ch := make(chan WorkUpdate, 4)
	wb.mu.Lock()
	wb.subscribers[id] = ch
	wb.mu.Unlock()
	return id, ch
}

func (wb *WorkBroadcaster) unsubscribe(id int64) {
	wb.mu.Lock()
	delete(wb.subscribers, id)
	wb.mu.Unlock()
}

func (wb *WorkBroadcaster) broadcast(w WorkUpdate) {
	wb.mu.Lock()
	wb.current = w
	for _, ch := range wb.subscribers {
		select {
		case ch <- w:
		default:
		}
	}
	wb.mu.Unlock()
}

func (wb *WorkBroadcaster) getCurrent() WorkUpdate {
	wb.mu.RLock()
	defer wb.mu.RUnlock()
	return wb.current
}

// ─── Global counters ─────────────────────────────────────────────────────────

var (
	totalAccepted  int64
	totalRejected  int64
	totalConnected int64
	startTime      = time.Now()
)

// ─── Network stats ───────────────────────────────────────────────────────────

type NetStats struct {
	BlockHeight uint64
	Difficulty  string
	NetworkHR   float64 // MH/s
	Peers       int
	NodeUp      bool
	LastUpdated time.Time
}

var (
	netStatsMu sync.RWMutex
	netStats   NetStats
)

func pollNetStats() {
	for {
		s := NetStats{LastUpdated: time.Now()}

		if raw, err := rpcCall("eth_blockNumber", nil); err == nil {
			var hexNum string
			if json.Unmarshal(raw, &hexNum) == nil {
				n := new(big.Int)
				n.SetString(strings.TrimPrefix(hexNum, "0x"), 16)
				s.BlockHeight = n.Uint64()
			}
		}

		if raw, err := rpcCall("net_peerCount", nil); err == nil {
			var hexPeers string
			if json.Unmarshal(raw, &hexPeers) == nil {
				p := new(big.Int)
				p.SetString(strings.TrimPrefix(hexPeers, "0x"), 16)
				s.Peers = int(p.Int64())
			}
		}

		type blockResult struct {
			Difficulty string `json:"difficulty"`
		}
		if raw, err := rpcCall("eth_getBlockByNumber", []interface{}{"latest", false}); err == nil {
			var block blockResult
			if json.Unmarshal(raw, &block) == nil && block.Difficulty != "" {
				s.Difficulty = block.Difficulty
				diff := new(big.Int)
				diff.SetString(strings.TrimPrefix(block.Difficulty, "0x"), 16)
				f, _ := new(big.Float).SetInt(diff).Float64()
				s.NetworkHR = f / 10.0 / 1e6 // difficulty / block_time(10s) → MH/s
				s.NodeUp = true
			}
		}

		netStatsMu.Lock()
		netStats = s
		netStatsMu.Unlock()

		time.Sleep(5 * time.Second)
	}
}

// ─── Miner registry ──────────────────────────────────────────────────────────

type MinerInfo struct {
	ID          int64
	Worker      string
	Address     string
	Hashrate    float64 // MH/s (from eth_submitHashrate)
	Accepted    int64
	Rejected    int64
	ConnectedAt time.Time
	LastSeen    time.Time
}

func isHexAddressLike(v string) bool {
	v = strings.TrimSpace(v)
	if len(v) != 42 {
		return false
	}
	if !strings.HasPrefix(strings.ToLower(v), "0x") {
		return false
	}
	for _, ch := range v[2:] {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') && (ch < 'A' || ch > 'F') {
			return false
		}
	}
	return true
}

// parseMinerIdentity accepts either "address.worker", "address", or "worker".
// Returns parsed address/worker while keeping backward-compatible worker-only logins.
func parseMinerIdentity(raw string) (string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", ""
	}

	if parts := strings.SplitN(raw, ".", 2); len(parts) == 2 {
		addr := strings.TrimSpace(parts[0])
		worker := strings.TrimSpace(parts[1])
		if !isHexAddressLike(addr) {
			// Treat invalid left side as worker-only input.
			if worker == "" {
				return "", raw
			}
			return "", worker
		}
		if worker == "" {
			worker = addr
		}
		return addr, worker
	}

	if isHexAddressLike(raw) {
		return raw, raw
	}
	return "", raw
}

func parseWorkerHint(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.EqualFold(raw, "x") {
		return ""
	}
	if addr, worker := parseMinerIdentity(raw); worker != "" && worker != addr {
		return worker
	}
	if isHexAddressLike(raw) {
		return ""
	}
	return raw
}

func resolveMinerIdentity(params []string, fallbackWorker string) (string, string) {
	address := ""
	worker := ""
	if len(params) > 0 {
		address, worker = parseMinerIdentity(params[0])
	}
	if worker == "" || worker == address {
		for _, param := range params[1:] {
			if hint := parseWorkerHint(param); hint != "" {
				worker = hint
				break
			}
		}
	}
	if worker == "" {
		worker = fallbackWorker
	}
	return address, worker
}

var (
	minersMu     sync.RWMutex
	activeMiners = map[int64]*MinerInfo{}
)

func registerMiner(id int64) {
	minersMu.Lock()
	activeMiners[id] = &MinerInfo{ID: id, ConnectedAt: time.Now(), LastSeen: time.Now()}
	minersMu.Unlock()
}

func unregisterMiner(id int64) {
	minersMu.Lock()
	delete(activeMiners, id)
	minersMu.Unlock()
}

func updateMinerWorker(id int64, worker, address string) {
	minersMu.Lock()
	if m, ok := activeMiners[id]; ok {
		m.Worker = worker
		m.Address = address
		m.LastSeen = time.Now()
	}
	minersMu.Unlock()
}

func updateMinerHashrate(id int64, hrHex string) {
	hr := new(big.Int)
	hr.SetString(strings.TrimPrefix(hrHex, "0x"), 16)
	hrFloat, _ := new(big.Float).SetInt(hr).Float64()
	minersMu.Lock()
	if m, ok := activeMiners[id]; ok {
		m.Hashrate = hrFloat / 1e6
		m.LastSeen = time.Now()
	}
	minersMu.Unlock()
}

func incMinerAccepted(id int64) {
	minersMu.Lock()
	if m, ok := activeMiners[id]; ok {
		m.Accepted++
		m.LastSeen = time.Now()
	}
	minersMu.Unlock()
}

func incMinerRejected(id int64) {
	minersMu.Lock()
	if m, ok := activeMiners[id]; ok {
		m.Rejected++
		m.LastSeen = time.Now()
	}
	minersMu.Unlock()
}

func getPoolHashrate() float64 {
	minersMu.RLock()
	defer minersMu.RUnlock()
	var total float64
	for _, m := range activeMiners {
		if m.Hashrate > 0 {
			total += m.Hashrate
			continue
		}
		// Some ASIC miners do not report eth_submitHashrate; estimate from shares.
		if time.Since(m.LastSeen) < 2*time.Minute {
			total += estimateWorkerHashrate(m.Worker, 5*time.Minute)
		}
	}
	return total
}

// ─── Block and share tracking ────────────────────────────────────────────────

type ShareEvent struct {
	Worker string
	At     time.Time
	Valid  bool
}

type BlockRecord struct {
	Worker   string
	BlockNum uint64
	At       time.Time
	Reward   float64
}

var (
	sharesMu     sync.Mutex
	recentShares []ShareEvent // cap 200

	blocksMu     sync.Mutex
	recentBlocks []BlockRecord // cap 10000

	confirmedBlocksMu        sync.RWMutex
	confirmedPoolBlocks      []BlockRecord
	confirmedBlocksRefreshed time.Time
	confirmedRefreshRunning  int32
)

func recordShare(worker string, valid bool) {
	sharesMu.Lock()
	recentShares = append(recentShares, ShareEvent{Worker: worker, At: time.Now(), Valid: valid})
	if len(recentShares) > 200 {
		recentShares = recentShares[len(recentShares)-200:]
	}
	sharesMu.Unlock()

	if valid {
		atomic.AddInt64(&totalAccepted, 1)
	} else {
		atomic.AddInt64(&totalRejected, 1)
	}
}

func recordBlockFound(worker string) {
	latestHex := rpcHexString("eth_blockNumber", nil)
	latestNum := hexToUint64(latestHex)

	blockFound := map[string]interface{}{
		"worker":    worker,
		"blockNum":  latestNum + 1,
		"timestamp": time.Now().Unix(),
	}

	filePath := "/root/block-finders.json"
	var blocks []map[string]interface{}

	if data, err := os.ReadFile(filePath); err == nil {
		json.Unmarshal(data, &blocks)
	}

	blocks = append(blocks, blockFound)
	if len(blocks) > 10000 {
		blocks = blocks[len(blocks)-10000:]
	}

	if data, err := json.MarshalIndent(blocks, "", "  "); err == nil {
		os.WriteFile(filePath, data, 0644)
		log.Printf("[block-found] %s found block %d", worker, blockFound["blockNum"])
	}
}

func countHistoricalPoolBlockRecords(minerAddress string) ([]BlockRecord, error) {
	minerAddress = strings.ToLower(strings.TrimSpace(minerAddress))
	if minerAddress == "" {
		return nil, fmt.Errorf("missing miner address")
	}

	latestHex := rpcHexString("eth_blockNumber", nil)
	latest := hexToUint64(latestHex)
	blocks := make([]BlockRecord, 0)

	for blockNum := uint64(0); blockNum <= latest; blockNum++ {
		blockHex := fmt.Sprintf("0x%x", blockNum)
		raw, err := rpcCall("eth_getBlockByNumber", []interface{}{blockHex, false})
		if err != nil {
			return blocks, err
		}
		var block struct {
			Number    string `json:"number"`
			Miner     string `json:"miner"`
			Timestamp string `json:"timestamp"`
		}
		if err := json.Unmarshal(raw, &block); err != nil {
			continue
		}
		if strings.EqualFold(block.Miner, minerAddress) {
			resolvedNum := hexToUint64(block.Number)
			if resolvedNum == 0 && blockNum > 0 {
				resolvedNum = blockNum
			}
			blocks = append(blocks, BlockRecord{
				Worker:   minerAddress,
				BlockNum: resolvedNum,
				At:       time.Unix(int64(hexToUint64(block.Timestamp)), 0),
				Reward:   5.0,
			})
		}
	}

	return blocks, nil
}

func getConfirmedPoolBlocks() []BlockRecord {
	confirmedBlocksMu.RLock()
	cached := append([]BlockRecord(nil), confirmedPoolBlocks...)
	refreshed := confirmedBlocksRefreshed
	confirmedBlocksMu.RUnlock()

	if len(cached) > 0 && time.Since(refreshed) < 30*time.Second {
		return cached
	}

	miner := getPoolEtherbase()
	if miner == "" {
		return cached
	}

	blocks, err := countHistoricalPoolBlockRecords(miner)
	if err != nil {
		log.Printf("[totals] actual block refresh failed: %v", err)
		return cached
	}

	// Keep one record per block height to prevent stale/duplicate rows.
	if len(blocks) > 1 {
		dedup := make(map[uint64]BlockRecord, len(blocks))
		for _, b := range blocks {
			if b.BlockNum == 0 {
				continue
			}
			existing, ok := dedup[b.BlockNum]
			if !ok || b.At.After(existing.At) {
				dedup[b.BlockNum] = b
			}
		}
		if len(dedup) > 0 {
			uniq := make([]BlockRecord, 0, len(dedup))
			for _, b := range dedup {
				uniq = append(uniq, b)
			}
			sort.Slice(uniq, func(i, j int) bool { return uniq[i].BlockNum < uniq[j].BlockNum })
			blocks = uniq
		}
	}

	confirmedBlocksMu.Lock()
	confirmedPoolBlocks = append([]BlockRecord(nil), blocks...)
	confirmedBlocksRefreshed = time.Now()
	confirmedBlocksMu.Unlock()

	return append([]BlockRecord(nil), blocks...)
}

func getConfirmedPoolBlocksCached() []BlockRecord {
	confirmedBlocksMu.RLock()
	defer confirmedBlocksMu.RUnlock()
	return append([]BlockRecord(nil), confirmedPoolBlocks...)
}

func getSessionConfirmedPoolBlocksCached() []BlockRecord {
	all := getConfirmedPoolBlocksCached()
	out := make([]BlockRecord, 0, len(all))
	for _, block := range all {
		if !block.At.Before(startTime) {
			out = append(out, block)
		}
	}
	return out
}

func triggerConfirmedBlocksRefresh() {
	if !atomic.CompareAndSwapInt32(&confirmedRefreshRunning, 0, 1) {
		return
	}
	go func() {
		defer atomic.StoreInt32(&confirmedRefreshRunning, 0)
		_ = getConfirmedPoolBlocks()
	}()
}

func getSessionConfirmedPoolBlocks() []BlockRecord {
	all := getConfirmedPoolBlocks()
	out := make([]BlockRecord, 0, len(all))
	for _, block := range all {
		if !block.At.Before(startTime) {
			out = append(out, block)
		}
	}
	return out
}

// ─── Settings persistence ─────────────────────────────────────────────────────

type PayoutConfig struct {
	MiningAddress string  `json:"miningAddress"`
	MinPayment    float64 `json:"minPayment"`
}

type BlockTotals struct {
	TotalBlocks  int64            `json:"totalBlocks"`
	WorkerBlocks map[string]int64 `json:"workerBlocks"`
}

var (
	payoutCfgMu    sync.RWMutex
	payoutCfg      = PayoutConfig{MinPayment: 0.1}
	workerLabelsMu sync.RWMutex
	workerLabels   = map[string]string{}
	totalMinedMu   sync.Mutex
	totalMined     float64
	blockTotalsMu  sync.RWMutex
	blockTotals    = BlockTotals{WorkerBlocks: map[string]int64{}}
)

// poolEtherbase is the node's configured mining reward address, fetched at startup.
var (
	poolEtherbaseMu sync.RWMutex
	poolEtherbase   string
)

func fetchEtherbase() {
	// Use flag value immediately if provided — no need to poll eth_coinbase.
	if *etherbaseFlag != "" {
		poolEtherbaseMu.Lock()
		poolEtherbase = *etherbaseFlag
		poolEtherbaseMu.Unlock()
		log.Printf("[pool] Etherbase (reward address): %s", *etherbaseFlag)
		return
	}
	for {
		raw, err := rpcCall("eth_coinbase", nil)
		if err == nil {
			var addr string
			if json.Unmarshal(raw, &addr) == nil && addr != "" {
				poolEtherbaseMu.Lock()
				poolEtherbase = addr
				poolEtherbaseMu.Unlock()
				log.Printf("[pool] Etherbase (reward address): %s", addr)
				return
			}
		}
		log.Printf("[pool] Waiting for etherbase from node...")
		time.Sleep(5 * time.Second)
	}
}

func getPoolEtherbase() string {
	poolEtherbaseMu.RLock()
	defer poolEtherbaseMu.RUnlock()
	return poolEtherbase
}

func loadSettings() {
	if data, err := os.ReadFile(filepath.Join(*settingsDir, "payout.json")); err == nil {
		payoutCfgMu.Lock()
		json.Unmarshal(data, &payoutCfg)
		payoutCfgMu.Unlock()
	}
	if data, err := os.ReadFile(filepath.Join(*settingsDir, "workers.json")); err == nil {
		workerLabelsMu.Lock()
		json.Unmarshal(data, &workerLabels)
		workerLabelsMu.Unlock()
	}
	if data, err := os.ReadFile(filepath.Join(*settingsDir, "block_totals.json")); err == nil {
		blockTotalsMu.Lock()
		_ = json.Unmarshal(data, &blockTotals)
		if blockTotals.WorkerBlocks == nil {
			blockTotals.WorkerBlocks = map[string]int64{}
		}
		if blockTotals.TotalBlocks == 0 && len(blockTotals.WorkerBlocks) > 0 {
			var sum int64
			for _, count := range blockTotals.WorkerBlocks {
				sum += count
			}
			blockTotals.TotalBlocks = sum
		}
		blockTotalsMu.Unlock()
	}
}

func savePayoutCfg() {
	payoutCfgMu.RLock()
	data, _ := json.MarshalIndent(payoutCfg, "", "  ")
	payoutCfgMu.RUnlock()
	os.WriteFile(filepath.Join(*settingsDir, "payout.json"), data, 0644)
}

func saveWorkerLabels() {
	workerLabelsMu.RLock()
	data, _ := json.MarshalIndent(workerLabels, "", "  ")
	workerLabelsMu.RUnlock()
	os.WriteFile(filepath.Join(*settingsDir, "workers.json"), data, 0644)
}

func saveBlockTotals() {
	blockTotalsMu.RLock()
	data, _ := json.MarshalIndent(blockTotals, "", "  ")
	blockTotalsMu.RUnlock()
	_ = os.WriteFile(filepath.Join(*settingsDir, "block_totals.json"), data, 0644)
}

func countHistoricalPoolBlocks(minerAddress string) (int64, error) {
	minerAddress = strings.ToLower(strings.TrimSpace(minerAddress))
	if minerAddress == "" {
		return 0, fmt.Errorf("missing miner address")
	}

	latestHex := rpcHexString("eth_blockNumber", nil)
	latest := hexToUint64(latestHex)
	var total int64

	for blockNum := uint64(0); blockNum <= latest; blockNum++ {
		blockHex := fmt.Sprintf("0x%x", blockNum)
		raw, err := rpcCall("eth_getBlockByNumber", []interface{}{blockHex, false})
		if err != nil {
			return total, err
		}
		var block struct {
			Miner string `json:"miner"`
		}
		if err := json.Unmarshal(raw, &block); err != nil {
			continue
		}
		if strings.EqualFold(block.Miner, minerAddress) {
			total++
		}
	}

	return total, nil
}

func backfillHistoricalBlockTotals() {
	blockTotalsMu.RLock()
	existing := blockTotals.TotalBlocks
	blockTotalsMu.RUnlock()
	if existing > 0 {
		return
	}

	miner := getPoolEtherbase()
	if miner == "" {
		return
	}

	log.Printf("[totals] No persisted totals found. Backfilling historical blocks for %s", miner)
	total, err := countHistoricalPoolBlocks(miner)
	if err != nil {
		log.Printf("[totals] Historical backfill failed: %v", err)
		return
	}

	if total <= 0 {
		log.Printf("[totals] Historical backfill found no blocks")
		return
	}

	const historicalBucket = "historical-unattributed"

	blockTotalsMu.Lock()
	if blockTotals.WorkerBlocks == nil {
		blockTotals.WorkerBlocks = map[string]int64{}
	}
	if blockTotals.TotalBlocks < total {
		blockTotals.TotalBlocks = total
	}
	if blockTotals.WorkerBlocks[historicalBucket] < total {
		blockTotals.WorkerBlocks[historicalBucket] = total
	}
	blockTotalsMu.Unlock()

	saveBlockTotals()
	log.Printf("[totals] Historical backfill complete: %d total pool blocks", total)
}

// ─── Miner HR history ─────────────────────────────────────────────────────────

type HRSample struct {
	T  time.Time
	HR float64
}

var (
	minerHRMu      sync.Mutex
	minerHRHistory = map[string][]HRSample{}
)

func sampleMinerHashrates() {
	for range time.Tick(30 * time.Second) {
		minersMu.RLock()
		snapshot := make(map[string]float64)
		for _, m := range activeMiners {
			if m.Worker != "" {
				snapshot[m.Worker] = m.Hashrate
			}
		}
		minersMu.RUnlock()

		now := time.Now()
		minerHRMu.Lock()
		for worker, hr := range snapshot {
			minerHRHistory[worker] = append(minerHRHistory[worker], HRSample{T: now, HR: hr})
			if len(minerHRHistory[worker]) > 60 {
				minerHRHistory[worker] = minerHRHistory[worker][len(minerHRHistory[worker])-60:]
			}
		}
		minerHRMu.Unlock()
	}
}

// ─── Wallet / stat helpers ────────────────────────────────────────────────────

func getAccounts() []string {
	raw, err := rpcCall("eth_accounts", nil)
	if err != nil {
		return nil
	}
	var accounts []string
	json.Unmarshal(raw, &accounts)
	return accounts
}

func weiHexToETHII(hexBal string) float64 {
	bal := new(big.Int)
	bal.SetString(strings.TrimPrefix(hexBal, "0x"), 16)
	exp := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	f, _ := new(big.Float).Quo(new(big.Float).SetInt(bal), new(big.Float).SetInt(exp)).Float64()
	return f
}

func getBalance(address, tag string) float64 {
	raw, err := rpcCall("eth_getBalance", []interface{}{address, tag})
	if err != nil {
		return 0
	}
	var hexBal string
	json.Unmarshal(raw, &hexBal)
	return weiHexToETHII(hexBal)
}

func hexToUint64(hexValue string) uint64 {
	value := new(big.Int)
	if _, ok := value.SetString(strings.TrimPrefix(hexValue, "0x"), 16); !ok {
		return 0
	}
	return value.Uint64()
}

func hexToDecString(hexValue string) string {
	value := new(big.Int)
	if _, ok := value.SetString(strings.TrimPrefix(hexValue, "0x"), 16); !ok {
		return "0"
	}
	return value.String()
}

func rpcHexString(method string, params []interface{}) string {
	raw, err := rpcCall(method, params)
	if err != nil {
		return ""
	}
	var out string
	json.Unmarshal(raw, &out)
	return out
}

type explorerBlockRPC struct {
	Number       string            `json:"number"`
	Hash         string            `json:"hash"`
	ParentHash   string            `json:"parentHash"`
	Miner        string            `json:"miner"`
	Timestamp    string            `json:"timestamp"`
	Transactions []json.RawMessage `json:"transactions"`
	GasUsed      string            `json:"gasUsed"`
	GasLimit     string            `json:"gasLimit"`
	Difficulty   string            `json:"difficulty"`
	Size         string            `json:"size"`
	ExtraData    string            `json:"extraData"`
}

func decodeTransactions(items []json.RawMessage) []interface{} {
	out := make([]interface{}, 0, len(items))
	for _, item := range items {
		var decoded interface{}
		if err := json.Unmarshal(item, &decoded); err == nil {
			out = append(out, decoded)
		}
	}
	return out
}

func formatExplorerBlock(block *explorerBlockRPC, full bool) map[string]interface{} {
	if block == nil {
		return nil
	}
	out := map[string]interface{}{
		"number":     hexToUint64(block.Number),
		"hash":       block.Hash,
		"parentHash": block.ParentHash,
		"miner":      block.Miner,
		"timestamp":  hexToUint64(block.Timestamp),
		"txCount":    len(block.Transactions),
		"gasUsed":    hexToUint64(block.GasUsed),
		"gasLimit":   hexToUint64(block.GasLimit),
		"difficulty": hexToDecString(block.Difficulty),
		"size":       hexToUint64(block.Size),
		"extraData":  block.ExtraData,
	}
	if full {
		out["transactions"] = decodeTransactions(block.Transactions)
	}
	return out
}

func sharesPerMin() float64 {
	sharesMu.Lock()
	defer sharesMu.Unlock()
	cutoff := time.Now().Add(-60 * time.Second)
	count := 0
	for _, s := range recentShares {
		if s.At.After(cutoff) && s.Valid {
			count++
		}
	}
	return float64(count)
}

func currentDifficultyFloat() float64 {
	netStatsMu.RLock()
	dHex := netStats.Difficulty
	netStatsMu.RUnlock()
	if dHex == "" || dHex == "0x0" {
		return 0
	}
	d := new(big.Int)
	if _, ok := d.SetString(strings.TrimPrefix(dHex, "0x"), 16); !ok || d.Sign() == 0 {
		return 0
	}
	f, _ := new(big.Float).SetInt(d).Float64()
	return f
}

// estimateWorkerHashrate estimates MH/s from recent valid shares.
// Equation: hashrate = shares_per_second * difficulty.
func estimateWorkerHashrate(worker string, window time.Duration) float64 {
	if worker == "" {
		return 0
	}
	cutoff := time.Now().Add(-window)
	count := 0

	sharesMu.Lock()
	for _, s := range recentShares {
		if s.Valid && s.Worker == worker && s.At.After(cutoff) {
			count++
		}
	}
	sharesMu.Unlock()

	if count < 2 {
		return 0
	}

	difficulty := currentDifficultyFloat()
	if difficulty <= 0 {
		return 0
	}

	// Use the full rolling window for stability; short windows spike too much.
	elapsed := window.Seconds()
	if elapsed <= 0 {
		return 0
	}

	sharesPerSecond := float64(count) / elapsed
	est := (sharesPerSecond * difficulty) / 1e6 // MH/s

	// Keep estimates within sane bounds relative to current network hashrate.
	netStatsMu.RLock()
	netHR := netStats.NetworkHR
	netStatsMu.RUnlock()
	if netHR > 0 && est > netHR*1.2 {
		est = netHR * 1.2
	}
	return est
}

func roundLuck() float64 {
	netStatsMu.RLock()
	diff := netStats.Difficulty
	netStatsMu.RUnlock()
	if diff == "" || diff == "0x0" {
		return 0
	}
	d := new(big.Int)
	d.SetString(strings.TrimPrefix(diff, "0x"), 16)
	if d.Sign() == 0 {
		return 0
	}
	poolHR := getPoolHashrate() * 1e6
	if poolHR == 0 {
		return 0
	}
	accepted := float64(atomic.LoadInt64(&totalAccepted))
	if accepted == 0 {
		return 0
	}
	dF, _ := new(big.Float).SetInt(d).Float64()
	expected := dF / poolHR
	return accepted / expected * 100
}

// ─── Stratum message ─────────────────────────────────────────────────────────

type stratumMsg struct {
	ID     interface{}     `json:"id"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result interface{}     `json:"result,omitempty"`
	Error  interface{}     `json:"error,omitempty"`
}

// targetFromDiff converts difficulty hex string to a target big.Int hex string
func targetFromDiff(diffHex string) string {
	diffHex = strings.TrimPrefix(diffHex, "0x")
	diff := new(big.Int)
	diff.SetString(diffHex, 16)
	if diff.Sign() == 0 {
		diff.SetInt64(1)
	}
	maxUint256 := new(big.Int).Lsh(big.NewInt(1), 256)
	target := new(big.Int).Div(maxUint256, diff)
	return fmt.Sprintf("0x%064x", target)
}

// ─── Miner session ───────────────────────────────────────────────────────────

type Miner struct {
	id       int64
	conn     net.Conn
	writer   *bufio.Writer
	workerID string
	wb       *WorkBroadcaster
	mu       sync.Mutex
	ethProxy bool // true = EthProxy protocol (eth_submitLogin/eth_getWork)
	mode     stratumMode
}

func (m *Miner) send(msg stratumMsg) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.writer.Write(data)
	m.writer.WriteByte('\n')
	return m.writer.Flush()
}

func (m *Miner) sendWork(w WorkUpdate) {
	if m.ethProxy {
		// EthProxy new-job push: id=0 signals a new job to the miner.
		// Rigel and similar EthProxy miners do NOT always re-poll after a submit;
		// they rely on the server pushing id:0 work updates for job changes.
		// Using id:null caused Rigel to fail to parse and keep mining stale work.
		m.sendWorkEthProxyWithID(0, w)
		return
	}
	if m.mode == modeA10Compat {
		m.sendWorkA10(w)
		return
	}
	// Stratum protocol: mining.notify push
	// w.Target is already the mining boundary (2^256/difficulty) returned by
	// ethash_getWork. Pass it through directly — do NOT call targetFromDiff,
	// which would invert it again and produce an impossibly hard target.
	target := w.Target
	if !strings.HasPrefix(target, "0x") {
		target = "0x" + target
	}
	m.send(stratumMsg{
		ID:     nil,
		Method: "mining.notify",
		Params: jsonMarshal([]interface{}{w.HeaderHash, w.SeedHash, target, true}),
	})
}

func makeA10JobID(w WorkUpdate) string {
	height := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(w.Height)), "0x")
	if height == "" {
		height = "0"
	}
	header := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(w.HeaderHash)), "0x")
	if len(header) >= 8 {
		header = header[:8]
	} else if header == "" {
		header = "0"
	}
	return fmt.Sprintf("%s-%s", height, header)
}

func (m *Miner) sendA10SetDifficulty() {
	if *a10Difficulty <= 0 {
		return
	}
	m.send(stratumMsg{
		ID:     nil,
		Method: "mining.set_difficulty",
		Params: jsonMarshal([]interface{}{*a10Difficulty}),
	})
}

func (m *Miner) sendWorkA10(w WorkUpdate) {
	target := w.Target
	if !strings.HasPrefix(target, "0x") {
		target = "0x" + target
	}
	jobID := makeA10JobID(w)
	order := strings.ToLower(strings.TrimSpace(*a10NotifyOrder))
	params := []interface{}{jobID, w.HeaderHash, w.SeedHash, target, true}
	if order == "job-seed-header" {
		params = []interface{}{jobID, w.SeedHash, w.HeaderHash, target, true}
	}
	m.send(stratumMsg{
		ID:     nil,
		Method: "mining.notify",
		Params: jsonMarshal(params),
	})
}

// sendWorkEthProxy sends work as an eth_getWork response (EthProxy protocol).
func (m *Miner) sendWorkEthProxy(w WorkUpdate) {
	m.sendWorkEthProxyWithID(nil, w)
}

func (m *Miner) sendWorkEthProxyWithID(id interface{}, w WorkUpdate) {
	target := w.Target
	if !strings.HasPrefix(target, "0x") {
		target = "0x" + target
	}
	height := w.Height
	if height == "" {
		height = "0x0"
	}
	m.send(stratumMsg{
		ID:     id,
		Result: jsonMarshal([]string{w.HeaderHash, w.SeedHash, target, height}),
	})
}

func jsonMarshal(v interface{}) json.RawMessage {
	b, _ := json.Marshal(v)
	return json.RawMessage(b)
}

func handleMiner(conn net.Conn, wb *WorkBroadcaster, mode stratumMode) {
	defer conn.Close()
	atomic.AddInt64(&totalConnected, 1)
	defer atomic.AddInt64(&totalConnected, -1)

	subID, workCh := wb.subscribe()
	defer wb.unsubscribe(subID)

	registerMiner(subID)
	defer unregisterMiner(subID)

	m := &Miner{
		id:     subID,
		conn:   conn,
		writer: bufio.NewWriter(conn),
		wb:     wb,
		mode:   mode,
	}

	addr := conn.RemoteAddr().String()
	log.Printf("[+] Miner connected: %s", addr)
	defer log.Printf("[-] Miner disconnected: %s", addr)

	authorized := false
	scanner := bufio.NewScanner(conn)

	go func() {
		for w := range workCh {
			if authorized {
				m.sendWork(w)
			}
		}
	}()

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		var msg stratumMsg
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			continue
		}
		log.Printf("[req] miner=%d method=%s id=%v", subID, msg.Method, msg.ID)

		switch msg.Method {
		case "mining.subscribe":
			if m.mode == modeA10Compat {
				m.send(stratumMsg{
					ID: msg.ID,
					Result: []interface{}{
						[]interface{}{
							[]string{"mining.notify", fmt.Sprintf("%d", subID)},
							[]string{"mining.set_difficulty", fmt.Sprintf("%d", subID)},
						},
						fmt.Sprintf("%016x", subID),
						8,
					},
					Error: nil,
				})
				m.sendA10SetDifficulty()
			} else {
				m.send(stratumMsg{
					ID:     msg.ID,
					Result: []interface{}{[]interface{}{[]string{"mining.notify", fmt.Sprintf("%d", subID)}}, fmt.Sprintf("%016x", subID), 8},
					Error:  nil,
				})
			}

		case "mining.authorize":
			var params []string
			json.Unmarshal(msg.Params, &params)
			address, worker := resolveMinerIdentity(params, fmt.Sprintf("miner-%d", subID))
			if address == "" {
				address = getPoolEtherbase()
			}
			m.workerID = worker
			updateMinerWorker(subID, worker, address)
			m.send(stratumMsg{ID: msg.ID, Result: true, Error: nil})
			authorized = true
			log.Printf("    Worker authorized: %s (miner addr: %s)", worker, address)
			if w := wb.getCurrent(); w.HeaderHash != "" {
				m.sendWork(w)
			}

		case "mining.submit":
			var params []string
			json.Unmarshal(msg.Params, &params)
			if len(params) >= 5 {
				nonce, header, mix := params[2], params[3], params[4]
				ok, err := submitWork(nonce, header, mix)
				if err != nil || !ok {
					incMinerRejected(subID)
					recordShare(m.workerID, false)
					log.Printf("    Share rejected from %s: %v", m.workerID, err)
					m.send(stratumMsg{ID: msg.ID, Result: false, Error: "Share rejected"})
				} else {
					incMinerAccepted(subID)
					recordShare(m.workerID, true)
					recordBlockFound(m.workerID)
					log.Printf("    [BLOCK] Share accepted from %s", m.workerID)
					m.send(stratumMsg{ID: msg.ID, Result: true, Error: nil})
				}
			}

		case "eth_submitHashrate":
			var params []string
			json.Unmarshal(msg.Params, &params)
			if len(params) > 0 {
				updateMinerHashrate(subID, params[0])
			}
			m.send(stratumMsg{ID: msg.ID, Result: true, Error: nil})

		// ── EthProxy protocol (used by Rigel, ethminer, and others) ──────────
		case "eth_submitLogin":
			// Params: [address, x] — just accept any login
			var params []string
			json.Unmarshal(msg.Params, &params)
			address, worker := resolveMinerIdentity(params, fmt.Sprintf("miner-%d", subID))
			if address == "" {
				address = getPoolEtherbase()
			}
			m.workerID = worker
			m.ethProxy = true
			updateMinerWorker(subID, worker, address)
			m.send(stratumMsg{ID: msg.ID, Result: true, Error: nil})
			authorized = true
			log.Printf("    Worker authorized (EthProxy): %s (miner addr: %s)", worker, address)

		case "eth_getWork":
			if w := wb.getCurrent(); w.HeaderHash != "" {
				m.sendWorkEthProxyWithID(msg.ID, w)
			} else {
				m.send(stratumMsg{ID: msg.ID, Error: "no work available"})
			}

		case "eth_submitWork":
			// Params: [nonce, headerHash, mixDigest]
			var params []string
			json.Unmarshal(msg.Params, &params)
			if len(params) >= 3 {
				nonce, header, mix := params[0], params[1], params[2]
				ok, err := submitWork(nonce, header, mix)
				if err != nil || !ok {
					incMinerRejected(subID)
					recordShare(m.workerID, false)
					log.Printf("    Share rejected from %s: %v", m.workerID, err)
					m.send(stratumMsg{ID: msg.ID, Result: false, Error: "Share rejected"})
				} else {
					incMinerAccepted(subID)
					recordShare(m.workerID, true)
					recordBlockFound(m.workerID)
					log.Printf("    [BLOCK] Share accepted from %s", m.workerID)
					m.send(stratumMsg{ID: msg.ID, Result: true, Error: nil})
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("scanner error from %s: %v", addr, err)
	}
}

// ─── Work poller ─────────────────────────────────────────────────────────────

func pollWork(wb *WorkBroadcaster) {
	var lastHeader string
	// Resend current work every 30s even if unchanged — prevents miner keepalive timeout.
	keepaliveTick := time.NewTicker(30 * time.Second)
	defer keepaliveTick.Stop()
	for {
		work, err := getWork()
		if err != nil {
			log.Printf("[node] getWork error: %v", err)
			time.Sleep(3 * time.Second)
			continue
		}
		newJob := work[0] != lastHeader
		select {
		case <-keepaliveTick.C:
			newJob = true // force resend for keepalive
		default:
		}
		if newJob {
			lastHeader = work[0]
			wb.broadcast(WorkUpdate{
				HeaderHash: work[0],
				SeedHash:   work[1],
				Target:     work[2],
				Height:     work[3],
			})
			log.Printf("[work] New job: %s…", work[0][:18])
		}
		time.Sleep(*workInterval)
	}
}

// ─── Stats printer ───────────────────────────────────────────────────────────

func printStats() {
	for range time.Tick(60 * time.Second) {
		log.Printf("[stats] Miners: %d | Accepted: %d | Rejected: %d",
			atomic.LoadInt64(&totalConnected),
			atomic.LoadInt64(&totalAccepted),
			atomic.LoadInt64(&totalRejected))
	}
}

// ─── Dashboard HTTP server ────────────────────────────────────────────────────

func startDashboard(addr string) {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(dashboardHTML))
	})

	mux.HandleFunc("/api/stats", func(w http.ResponseWriter, r *http.Request) {
		netStatsMu.RLock()
		ns := netStats
		netStatsMu.RUnlock()

		// Keep stats endpoint lightweight; refresh confirmed blocks in background.
		triggerConfirmedBlocksRefresh()
		sessionBlocks := getSessionConfirmedPoolBlocksCached()
		blocksFound := len(sessionBlocks)
		allTimeBlocks := len(getConfirmedPoolBlocksCached())
		tm := float64(blocksFound) * 5.0

		stratumPort := *stratumAddr
		if parts := strings.Split(*stratumAddr, ":"); len(parts) > 0 {
			stratumPort = parts[len(parts)-1]
		}

		data := map[string]interface{}{
			"pool": map[string]interface{}{
				"hashrate":      getPoolHashrate(),
				"miners":        atomic.LoadInt64(&totalConnected),
				"accepted":      atomic.LoadInt64(&totalAccepted),
				"rejected":      atomic.LoadInt64(&totalRejected),
				"blocksFound":   blocksFound,
				"allTimeBlocks": allTimeBlocks,
				"stratumPort":   stratumPort,
				"fee":           devFeePercent,
				"sharesPerMin":  sharesPerMin(),
				"roundLuck":     roundLuck(),
				"totalMined":    tm,
				"etherbase":     getPoolEtherbase(),
			},
			"network": map[string]interface{}{
				"blockHeight": ns.BlockHeight,
				"difficulty":  ns.Difficulty,
				"hashrate":    ns.NetworkHR,
				"peers":       ns.Peers,
				"nodeUp":      ns.NodeUp,
			},
			"uptime": int64(time.Since(startTime).Seconds()),
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(w).Encode(data)
	})

	mux.HandleFunc("/api/chain/info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")

		numHex, err := rpcCall("eth_blockNumber", nil)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusServiceUnavailable)
			return
		}
		peerHex := rpcHexString("net_peerCount", nil)
		var blockNumberHex string
		json.Unmarshal(numHex, &blockNumberHex)
		blockRaw, err := rpcCall("eth_getBlockByNumber", []interface{}{blockNumberHex, false})
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusServiceUnavailable)
			return
		}
		var block explorerBlockRPC
		json.Unmarshal(blockRaw, &block)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"blockNumber": hexToUint64(blockNumberHex),
			"peers":       hexToUint64(peerHex),
			"chainId":     2048,
			"latestBlock": formatExplorerBlock(&block, false),
		})
	})

	mux.HandleFunc("/api/chain/blocks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")

		count := 20
		if raw := r.URL.Query().Get("count"); raw != "" {
			if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 50 {
				count = parsed
			}
		}
		offset := 0
		if raw := r.URL.Query().Get("offset"); raw != "" {
			if parsed, err := strconv.Atoi(raw); err == nil && parsed >= 0 {
				offset = parsed
			}
		}

		numHex := rpcHexString("eth_blockNumber", nil)
		latest := int(hexToUint64(numHex))
		out := make([]map[string]interface{}, 0, count)
		for i := offset; i < offset+count && latest-i >= 0; i++ {
			blockHex := fmt.Sprintf("0x%x", latest-i)
			blockRaw, err := rpcCall("eth_getBlockByNumber", []interface{}{blockHex, false})
			if err != nil {
				continue
			}
			var block explorerBlockRPC
			if err := json.Unmarshal(blockRaw, &block); err == nil {
				out = append(out, formatExplorerBlock(&block, false))
			}
		}
		json.NewEncoder(w).Encode(out)
	})

	mux.HandleFunc("/api/chain/block/hash/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		hash := strings.TrimPrefix(r.URL.Path, "/api/chain/block/hash/")
		if hash == "" {
			http.Error(w, `{"error":"Block not found"}`, http.StatusNotFound)
			return
		}
		blockRaw, err := rpcCall("eth_getBlockByHash", []interface{}{hash, true})
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusServiceUnavailable)
			return
		}
		var block explorerBlockRPC
		if err := json.Unmarshal(blockRaw, &block); err != nil || block.Hash == "" {
			http.Error(w, `{"error":"Block not found"}`, http.StatusNotFound)
			return
		}
		json.NewEncoder(w).Encode(formatExplorerBlock(&block, true))
	})

	mux.HandleFunc("/api/chain/block/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		id := strings.TrimPrefix(r.URL.Path, "/api/chain/block/")
		if id == "" {
			http.Error(w, `{"error":"Block not found"}`, http.StatusNotFound)
			return
		}
		param := id
		if !strings.HasPrefix(strings.ToLower(id), "0x") {
			parsed, err := strconv.ParseUint(id, 10, 64)
			if err != nil {
				http.Error(w, `{"error":"Block not found"}`, http.StatusNotFound)
				return
			}
			param = fmt.Sprintf("0x%x", parsed)
		}
		blockRaw, err := rpcCall("eth_getBlockByNumber", []interface{}{param, true})
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusServiceUnavailable)
			return
		}
		var block explorerBlockRPC
		if err := json.Unmarshal(blockRaw, &block); err != nil || block.Hash == "" {
			http.Error(w, `{"error":"Block not found"}`, http.StatusNotFound)
			return
		}
		json.NewEncoder(w).Encode(formatExplorerBlock(&block, true))
	})

	mux.HandleFunc("/api/chain/tx/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		hash := strings.TrimPrefix(r.URL.Path, "/api/chain/tx/")
		if hash == "" {
			http.Error(w, `{"error":"Transaction not found"}`, http.StatusNotFound)
			return
		}
		txRaw, err := rpcCall("eth_getTransactionByHash", []interface{}{hash})
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusServiceUnavailable)
			return
		}
		var tx map[string]interface{}
		if err := json.Unmarshal(txRaw, &tx); err != nil || len(tx) == 0 {
			http.Error(w, `{"error":"Transaction not found"}`, http.StatusNotFound)
			return
		}
		if receiptRaw, err := rpcCall("eth_getTransactionReceipt", []interface{}{hash}); err == nil {
			var receipt map[string]interface{}
			if json.Unmarshal(receiptRaw, &receipt) == nil && len(receipt) > 0 {
				tx["receipt"] = receipt
			}
		}
		tx["valueEth"] = weiHexToETHII(fmt.Sprint(tx["value"]))
		json.NewEncoder(w).Encode(tx)
	})

	mux.HandleFunc("/api/chain/address/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		address := strings.TrimPrefix(r.URL.Path, "/api/chain/address/")
		if address == "" {
			http.Error(w, `{"error":"Address not found"}`, http.StatusNotFound)
			return
		}
		balanceHex := rpcHexString("eth_getBalance", []interface{}{address, "latest"})
		txCountHex := rpcHexString("eth_getTransactionCount", []interface{}{address, "latest"})
		codeHex := rpcHexString("eth_getCode", []interface{}{address, "latest"})
		json.NewEncoder(w).Encode(map[string]interface{}{
			"address":    address,
			"balance":    weiHexToETHII(balanceHex),
			"txCount":    hexToUint64(txCountHex),
			"isContract": codeHex != "" && codeHex != "0x" && len(codeHex) > 2,
		})
	})

	mux.HandleFunc("/api/miners", func(w http.ResponseWriter, r *http.Request) {
		minersMu.RLock()
		list := make([]*MinerInfo, 0, len(activeMiners))
		for _, m := range activeMiners {
			cp := *m
			list = append(list, &cp)
		}
		minersMu.RUnlock()

		type minerJSON struct {
			ID                int64   `json:"id"`
			Worker            string  `json:"worker"`
			Label             string  `json:"label"`
			Address           string  `json:"address"`
			Hashrate          float64 `json:"hashrate"`
			ReportedHashrate  float64 `json:"reportedHashrate"`
			EstimatedHashrate float64 `json:"estimatedHashrate"`
			HashrateSource    string  `json:"hashrateSource"`
			Accepted          int64   `json:"accepted"`
			Rejected          int64   `json:"rejected"`
			AllTimeBlocks     int64   `json:"allTimeBlocks"`
			ConnectedAt       string  `json:"connectedAt"`
			LastSeen          string  `json:"lastSeen"`
		}
		out := make([]minerJSON, len(list))
		for i, m := range list {
			workerLabelsMu.RLock()
			label := workerLabels[m.Worker]
			workerLabelsMu.RUnlock()
			reported := m.Hashrate
			estimated := 0.0
			effective := reported
			source := "reported"
			if reported <= 0 {
				source = "none"
				if time.Since(m.LastSeen) < 2*time.Minute {
					estimated = estimateWorkerHashrate(m.Worker, 5*time.Minute)
					if estimated > 0 {
						effective = estimated
						source = "estimated"
					}
				}
			}
			out[i] = minerJSON{
				ID:                m.ID,
				Worker:            m.Worker,
				Label:             label,
				Address:           m.Address,
				Hashrate:          effective,
				ReportedHashrate:  reported,
				EstimatedHashrate: estimated,
				HashrateSource:    source,
				Accepted:          m.Accepted,
				Rejected:          m.Rejected,
				AllTimeBlocks:     0,
				ConnectedAt:       m.ConnectedAt.Format(time.RFC3339),
				LastSeen:          m.LastSeen.Format(time.RFC3339),
			}
		}

		sort.Slice(out, func(i, j int) bool {
			return out[i].Hashrate > out[j].Hashrate
		})
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(w).Encode(out)
	})

	mux.HandleFunc("/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		blocks := getSessionConfirmedPoolBlocks()
		etherbase := getPoolEtherbase()
		out := make([]map[string]interface{}, len(blocks))
		for i, b := range blocks {
			out[len(blocks)-1-i] = map[string]interface{}{
				"worker":   b.Worker,
				"address":  etherbase,
				"blockNum": b.BlockNum,
				"at":       b.At.Format(time.RFC3339),
				"reward":   b.Reward,
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(w).Encode(out)
	})

	mux.HandleFunc("/api/shares", func(w http.ResponseWriter, r *http.Request) {
		sharesMu.Lock()
		out := make([]map[string]interface{}, len(recentShares))
		for i, s := range recentShares {
			out[len(recentShares)-1-i] = map[string]interface{}{
				"worker": s.Worker,
				"at":     s.At.Format(time.RFC3339),
				"valid":  s.Valid,
			}
		}
		sharesMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(w).Encode(out)
	})

	// ── miner hashrate history ────────────────────────────────────────────
	mux.HandleFunc("/api/miner-history", func(w http.ResponseWriter, r *http.Request) {
		worker := r.URL.Query().Get("worker")

		minerHRMu.Lock()
		workers := make([]string, 0, len(minerHRHistory))
		for wk := range minerHRHistory {
			workers = append(workers, wk)
		}
		// include currently connected miners even if no history yet
		minersMu.RLock()
		for _, m := range activeMiners {
			if m.Worker == "" {
				continue
			}
			found := false
			for _, wk := range workers {
				if wk == m.Worker {
					found = true
					break
				}
			}
			if !found {
				workers = append(workers, m.Worker)
			}
		}
		minersMu.RUnlock()
		sort.Strings(workers)

		if worker == "" && len(workers) > 0 {
			worker = workers[0]
		}
		var samples []HRSample
		if worker != "" {
			samples = minerHRHistory[worker]
		}
		minerHRMu.Unlock()

		type sJSON struct {
			T  string  `json:"t"`
			HR float64 `json:"hr"`
		}
		type bJSON struct {
			T string `json:"t"`
			N uint64 `json:"n"`
		}
		out := make([]sJSON, len(samples))
		for i, s := range samples {
			out[i] = sJSON{T: s.T.Format(time.RFC3339), HR: s.HR}
		}
		confirmedBlocks := getSessionConfirmedPoolBlocks()
		var blks []bJSON
		for _, b := range confirmedBlocks {
			if worker == "" {
				blks = append(blks, bJSON{T: b.At.Format(time.RFC3339), N: b.BlockNum})
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"worker":  worker,
			"workers": workers,
			"samples": out,
			"blocks":  blks,
		})
	})

	// ── worker labels ─────────────────────────────────────────────────────
	mux.HandleFunc("/api/worker-labels", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
		if r.Method == "OPTIONS" {
			return
		}
		if r.Method == "POST" {
			var req struct {
				Worker string `json:"worker"`
				Label  string `json:"label"`
			}
			json.NewDecoder(r.Body).Decode(&req)
			if req.Worker != "" {
				workerLabelsMu.Lock()
				if req.Label == "" {
					delete(workerLabels, req.Worker)
				} else {
					workerLabels[req.Worker] = req.Label
				}
				workerLabelsMu.Unlock()
				saveWorkerLabels()
			}
			json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
			return
		}
		wBlockCounts := map[string]int{}

		type wRow struct {
			Worker      string  `json:"worker"`
			Label       string  `json:"label"`
			Status      string  `json:"status"`
			Hashrate    float64 `json:"hashrate"`
			BlocksFound int     `json:"blocksFound"`
		}
		seen := map[string]bool{}
		var rows []wRow
		minersMu.RLock()
		for _, m := range activeMiners {
			if m.Worker == "" {
				continue
			}
			workerLabelsMu.RLock()
			lbl := workerLabels[m.Worker]
			workerLabelsMu.RUnlock()
			rows = append(rows, wRow{Worker: m.Worker, Label: lbl, Status: "online", Hashrate: m.Hashrate, BlocksFound: wBlockCounts[m.Worker]})
			seen[m.Worker] = true
		}
		minersMu.RUnlock()
		workerLabelsMu.RLock()
		for wk, lbl := range workerLabels {
			if !seen[wk] {
				rows = append(rows, wRow{Worker: wk, Label: lbl, Status: "offline", BlocksFound: wBlockCounts[wk]})
			}
		}
		workerLabelsMu.RUnlock()
		json.NewEncoder(w).Encode(map[string]interface{}{"workers": rows})
	})

	// ── payout settings ───────────────────────────────────────────────────
	mux.HandleFunc("/api/payout", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
		if r.Method == "OPTIONS" {
			return
		}
		if r.Method == "POST" {
			var req PayoutConfig
			json.NewDecoder(r.Body).Decode(&req)
			payoutCfgMu.Lock()
			if req.MiningAddress != "" {
				payoutCfg.MiningAddress = req.MiningAddress
			}
			if req.MinPayment > 0 {
				payoutCfg.MinPayment = req.MinPayment
			}
			payoutCfgMu.Unlock()
			savePayoutCfg()
			json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
			return
		}
		payoutCfgMu.RLock()
		cfg := payoutCfg
		payoutCfgMu.RUnlock()
		json.NewEncoder(w).Encode(cfg)
	})

	// ── daemon version ────────────────────────────────────────────────────
	mux.HandleFunc("/api/daemon-version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		var nodeVer string
		if raw, err := rpcCall("web3_clientVersion", nil); err == nil {
			json.Unmarshal(raw, &nodeVer)
		}
		json.NewEncoder(w).Encode(map[string]interface{}{
			"nodeVersion":     nodeVer,
			"stratumVersion":  "1.0.0",
			"updateAvailable": false,
			"updateMessage":   "GitHub update check not yet configured",
		})
	})

	// ── wallet info ───────────────────────────────────────────────────────
	mux.HandleFunc("/api/wallet", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		accounts := getAccounts()
		address := ""
		if len(accounts) > 0 {
			address = accounts[0]
		}
		payoutCfgMu.RLock()
		if payoutCfg.MiningAddress != "" {
			address = payoutCfg.MiningAddress
		}
		payoutCfgMu.RUnlock()

		balance, pending := 0.0, 0.0
		if address != "" {
			balance = getBalance(address, "latest")
			pending = getBalance(address, "pending")
		}

		type txRec struct {
			Type   string  `json:"type"`
			Amount float64 `json:"amount"`
			At     string  `json:"at"`
			Block  uint64  `json:"block"`
		}
		confirmedBlocks := getConfirmedPoolBlocks()
		var txs []txRec
		for i := len(confirmedBlocks) - 1; i >= 0; i-- {
			b := confirmedBlocks[i]
			txs = append(txs, txRec{Type: "Mining Reward", Amount: b.Reward, At: b.At.Format(time.RFC3339), Block: b.BlockNum})
		}

		tm := float64(len(confirmedBlocks)) * 5.0
		json.NewEncoder(w).Encode(map[string]interface{}{
			"address":     address,
			"allAccounts": accounts,
			"balance":     balance,
			"pending":     pending,
			"totalMined":  tm,
			"txs":         txs,
		})
	})

	// ── wallet send ───────────────────────────────────────────────────────
	mux.HandleFunc("/api/wallet/send", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST,OPTIONS")
		if r.Method == "OPTIONS" {
			return
		}
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		var req struct {
			From     string  `json:"from"`
			To       string  `json:"to"`
			Amount   float64 `json:"amount"`
			Password string  `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid request"})
			return
		}
		if req.From == "" {
			accounts := getAccounts()
			if len(accounts) == 0 {
				json.NewEncoder(w).Encode(map[string]string{"error": "no accounts found"})
				return
			}
			req.From = accounts[0]
		}
		weiF := req.Amount * 1e18
		weiI := new(big.Int)
		weiI.SetString(fmt.Sprintf("%.0f", weiF), 10)
		valueHex := fmt.Sprintf("0x%x", weiI)
		// personal_unlockAccount is not available; skip — wallet handles signing
		txObj := map[string]interface{}{
			"from":     req.From,
			"to":       req.To,
			"value":    valueHex,
			"gas":      "0x5208",
			"gasPrice": "0x1DCD6500",
		}
		raw, err := rpcCall("eth_sendTransaction", []interface{}{txObj})
		if err != nil {
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		var txHash string
		json.Unmarshal(raw, &txHash)
		json.NewEncoder(w).Encode(map[string]string{"txHash": txHash, "status": "submitted"})
	})

	// ── generate address ──────────────────────────────────────────────────
	mux.HandleFunc("/api/wallet/generate-address", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST,OPTIONS")
		if r.Method == "OPTIONS" {
			return
		}
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		var req struct {
			Password string `json:"password"`
		}
		_ = req // unused; personal_newAccount not available
		// Account creation via personal_newAccount is not available.
		// Use the ETHII Wallet app to create and manage accounts.
		json.NewEncoder(w).Encode(map[string]string{"error": "use the ETHII Wallet app to create accounts"})
	})

	// ── logo ──────────────────────────────────────────────────────────────
	mux.HandleFunc("/logo", func(w http.ResponseWriter, r *http.Request) {
		candidates := []string{
			filepath.Join(*settingsDir, "ethii-logo.png"),
			filepath.Join(*settingsDir, "..", "wallet", "assets", "ethii-logo.png"),
		}
		for _, p := range candidates {
			if data, err := os.ReadFile(p); err == nil {
				w.Header().Set("Content-Type", "image/png")
				w.Header().Set("Cache-Control", "max-age=3600")
				w.Write(data)
				return
			}
		}
		w.WriteHeader(404)
	})

	log.Printf("[dashboard] http://%s", strings.Replace(addr, "0.0.0.0", "127.0.0.1", 1))
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("[dashboard] Error: %v", err)
	}
}

// ─── Main ─────────────────────────────────────────────────────────────────────

func main() {
	flag.Parse()

	fmt.Println("============================================")
	fmt.Println("  ETHII Stratum Proxy - ETH 2.0 PoW")
	fmt.Println("============================================")
	fmt.Printf("  Node RPC  : %s\n", *nodeURL)
	fmt.Printf("  Stratum   : %s\n", *stratumAddr)
	if strings.TrimSpace(*a10StratumAddr) != "" {
		fmt.Printf("  Stratum+A10: %s (%s)\n", *a10StratumAddr, *a10NotifyOrder)
	}
	fmt.Printf("  Dev Fee   : %.0f%% -> %s (hardcoded)\n", devFeePercent, devFeeAddress)
	if *dashboardAddr != "" {
		dashURL := strings.Replace(*dashboardAddr, "0.0.0.0", "127.0.0.1", 1)
		fmt.Printf("  Dashboard : http://%s\n", dashURL)
	}
	fmt.Println()

	wb := newWorkBroadcaster()

	loadSettings()
	go fetchEtherbase()
	go func() {
		for i := 0; i < 60; i++ {
			if getPoolEtherbase() != "" {
				backfillHistoricalBlockTotals()
				return
			}
			time.Sleep(1 * time.Second)
		}
		log.Printf("[totals] Skipping historical backfill: etherbase not available yet")
	}()
	go pollWork(wb)
	go pollNetStats()
	go printStats()
	go sampleMinerHashrates()

	if *dashboardAddr != "" {
		go startDashboard(*dashboardAddr)
	}

	if strings.TrimSpace(*a10StratumAddr) != "" {
		go func(addr string) {
			ln, err := net.Listen("tcp", addr)
			if err != nil {
				log.Printf("A10 compatibility listener disabled on %s: %v", addr, err)
				return
			}
			log.Printf("A10 compatibility stratum listening on %s (notify order: %s)", addr, *a10NotifyOrder)
			for {
				conn, err := ln.Accept()
				if err != nil {
					log.Printf("A10 accept error: %v", err)
					continue
				}
				go handleMiner(conn, wb, modeA10Compat)
			}
		}(*a10StratumAddr)
	}

	ln, err := net.Listen("tcp", *stratumAddr)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", *stratumAddr, err)
	}
	log.Printf("Stratum listening on %s", *stratumAddr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("Accept error: %v", err)
			continue
		}
		go handleMiner(conn, wb, modeStandard)
	}
}

// ─── Embedded dashboard HTML ──────────────────────────────────────────────────

const dashboardHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ETHII Solo Mining Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>
  :root {
    --bg: #080d14; --surface: #0d1520; --surface2: #141f2e; --border: #1e2d40;
    --accent: #00d4ff; --accent2: #00ff9d; --text: #dde8f0; --muted: #6b8299;
    --red: #ff4d6a; --green: #00e676; --yellow: #ffc107; --orange: #ff8c00;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 14px; }
  header { background: var(--surface); border-bottom: 1px solid var(--border); padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; position: sticky; top: 0; z-index: 100; }
  .logo { display: flex; align-items: center; gap: 12px; }
  .logo img { width: 40px; height: 40px; border-radius: 50%; box-shadow: 0 0 12px rgba(0,212,255,.5); }
  .logo-fallback { width: 40px; height: 40px; border-radius: 50%; background: linear-gradient(135deg, #00d4ff, #0044ff); display: flex; align-items: center; justify-content: center; font-weight: 900; color: #000; font-size: 12px; box-shadow: 0 0 12px rgba(0,212,255,.4); }
  .logo-text { font-size: 18px; font-weight: 700; }
  .logo-sub { font-size: 11px; color: var(--accent); letter-spacing: .06em; margin-top: 1px; }
  .status-bar { display: flex; gap: 16px; align-items: center; font-size: 12px; }
  .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); display: inline-block; margin-right: 5px; animation: pulse 2s infinite; }
  .status-dot.red { background: var(--red); animation: none; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.3} }
  .refresh-info { color: var(--muted); font-size: 11px; }
  .uptime-badge { display: inline-flex; align-items: center; padding: 3px 9px; border-radius: 999px; border: 1px solid var(--border); background: var(--surface2); color: var(--muted); font-size: 11px; font-weight: 700; }
  main { padding: 20px 24px; max-width: 1440px; margin: 0 auto; }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 12px; margin-bottom: 20px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
  .card-label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .06em; margin-bottom: 6px; }
  .card-value { font-size: 22px; font-weight: 700; }
  .card-sub { color: var(--muted); font-size: 11px; margin-top: 4px; }
  .card-accent  { border-top: 3px solid var(--accent); }
  .card-accent2 { border-top: 3px solid var(--accent2); }
  .card-green   { border-top: 3px solid var(--green); }
  .card-red     { border-top: 3px solid var(--red); }
  .card-yellow  { border-top: 3px solid var(--yellow); }
  .card-orange  { border-top: 3px solid var(--orange); }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 20px; }
  .grid-3 { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; margin-bottom: 20px; }
  @media(max-width:900px) { .grid-2,.grid-3 { grid-template-columns: 1fr; } }
  .panel { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; overflow: hidden; margin-bottom: 20px; }
  .panel-header { padding: 13px 18px; border-bottom: 1px solid var(--border); font-weight: 600; font-size: 13px; display: flex; align-items: center; justify-content: space-between; }
  .panel-header .badge { background: var(--surface2); border: 1px solid var(--border); border-radius: 12px; padding: 2px 8px; font-size: 11px; color: var(--muted); }
  .panel-body { padding: 16px 18px; }
  .chart-wrap { position: relative; height: 220px; padding: 12px 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .06em; padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); }
  td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: var(--surface2); }
  .mono { font-family: 'SF Mono', Consolas, monospace; font-size: 12px; }
  .addr { max-width: 160px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tag { display: inline-block; padding: 2px 7px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .tag-ok  { background: rgba(0,230,118,.12); color: var(--green); }
  .tag-bad { background: rgba(255,77,106,.12); color: var(--red); }
  .tag-warn { background: rgba(255,193,7,.12); color: var(--yellow); }
  .health-row { display: flex; align-items: center; justify-content: space-between; padding: 9px 0; border-bottom: 1px solid var(--border); }
  .health-row:last-child { border-bottom: none; }
  .health-label { color: var(--muted); font-size: 12px; }
  .health-val { font-size: 13px; font-weight: 600; }
  .health-ok   { color: var(--green); }
  .health-err  { color: var(--red); }
  .health-warn { color: var(--yellow); }
  .share-monitor { background: #060b12; border: 1px solid var(--border); border-radius: 6px; font-family: 'Courier New', monospace; font-size: 12px; height: 240px; overflow-y: auto; padding: 10px 12px; display: flex; flex-direction: column-reverse; }
  .sm-row { padding: 3px 0; border-bottom: 1px solid rgba(255,255,255,.03); display: flex; gap: 10px; align-items: baseline; }
  .sm-time { color: #3a5570; min-width: 75px; }
  .sm-worker { color: var(--accent); min-width: 150px; }
  .sm-valid  { color: var(--green); }
  .sm-invalid { color: var(--red); }
  .sm-wrap { display: none; margin-top: 12px; }
  .sm-wrap.open { display: block; }
  .btn { background: var(--accent); color: #000; border: none; border-radius: 6px; padding: 6px 14px; font-size: 12px; font-weight: 700; cursor: pointer; transition: opacity .15s; }
  .btn:hover { opacity: .85; }
  .btn-outline { background: transparent; color: var(--accent); border: 1px solid var(--accent); border-radius: 6px; padding: 5px 12px; font-size: 12px; font-weight: 600; cursor: pointer; transition: all .15s; }
  .btn-outline:hover { background: rgba(0,212,255,.1); }
  .btn-green { background: var(--green); color: #000; }
  .btn-red { background: var(--red); color: #fff; }
  #sm-toggle.active { background: #0a2035; color: var(--accent); border: 1px solid var(--accent); }
  .empty { color: var(--muted); text-align: center; padding: 24px; font-size: 13px; }
  .form-row { display: flex; gap: 8px; align-items: center; margin-bottom: 10px; flex-wrap: wrap; }
  .form-row label { color: var(--muted); font-size: 12px; min-width: 90px; }
  input[type=text], input[type=number], input[type=password], select {
    background: var(--surface2); border: 1px solid var(--border); border-radius: 6px;
    color: var(--text); padding: 7px 10px; font-size: 13px; flex: 1; min-width: 120px;
  }
  input:focus, select:focus { outline: none; border-color: var(--accent); }
  .balance-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; margin-bottom: 14px; }
  .bal-box { background: var(--surface2); border: 1px solid var(--border); border-radius: 8px; padding: 12px; text-align: center; }
  .bal-label { color: var(--muted); font-size: 11px; margin-bottom: 4px; }
  .bal-val { font-size: 18px; font-weight: 700; color: var(--accent2); }
  .miner-select-row { display: flex; align-items: center; gap: 10px; padding: 12px 16px; border-bottom: 1px solid var(--border); }
  .worker-status-on  { color: var(--green); font-size: 11px; font-weight: 600; }
  .worker-status-off { color: var(--muted); font-size: 11px; font-weight: 600; }
  footer { margin-top: 30px; padding: 20px; border-top: 1px solid var(--border); text-align: center; color: var(--muted); font-size: 12px; }
  footer a { color: var(--accent); text-decoration: none; }
  footer a:hover { text-decoration: underline; }
</style>
</head>
<body>

<header>
  <div class="logo">
    <img src="/logo" alt="ETHII" id="logo-img" onerror="document.getElementById('logo-img').style.display='none';document.getElementById('logo-fallback').style.display='flex'">
    <div class="logo-fallback" id="logo-fallback" style="display:none">E2</div>
    <div>
      <div class="logo-text">ETHII Solo Mining Dashboard</div>
      <div class="logo-sub">ETH 2.0 PROOF OF WORK &bull; CHAIN ID 2048 &bull; by <a href="https://www.youtube.com/@BitsPleaseYT" target="_blank" style="color:inherit">BitsPleaseYT</a></div>
    </div>
  </div>
  <div class="status-bar">
    <span class="uptime-badge" id="uptime-badge">uptime –</span>
    <span><span class="status-dot red" id="node-dot"></span><span id="node-txt">Node…</span></span>
    <span><span class="status-dot" id="stratum-dot"></span><span id="stratum-txt">Stratum</span></span>
    <span class="refresh-info" id="last-refresh">–</span>
  </div>
</header>

<main>

  <!-- ── 12 Top cards ────────────────────────────────────────────────────── -->
  <div class="cards">
    <div class="card card-accent">
      <div class="card-label">Pool Hashrate</div>
      <div class="card-value" id="pool-hr">–</div>
      <div class="card-sub" id="pool-miners">– miners</div>
    </div>
    <div class="card card-accent2">
      <div class="card-label">Network Hashrate</div>
      <div class="card-value" id="net-hr">–</div>
      <div class="card-sub">Ethash PoW</div>
    </div>
    <div class="card card-green">
      <div class="card-label">Network Difficulty</div>
      <div class="card-value" id="net-diff">–</div>
      <div class="card-sub" id="net-peers">– peers</div>
    </div>
    <div class="card card-yellow">
      <div class="card-label">Block Height</div>
      <div class="card-value" id="block-height">–</div>
      <div class="card-sub">current chain tip</div>
    </div>
    <div class="card card-orange">
      <div class="card-label">Block Reward</div>
      <div class="card-value" style="color:var(--orange)">5 ETHII</div>
      <div class="card-sub">fixed reward</div>
    </div>
    <div class="card card-green">
      <div class="card-label">Blocks Found</div>
      <div class="card-value" id="blocks-found">–</div>
      <div class="card-sub">this session</div>
    </div>
    <div class="card card-accent2">
      <div class="card-label">Total Mined</div>
      <div class="card-value" id="total-mined">–</div>
      <div class="card-sub">session rewards</div>
    </div>
    <div class="card card-accent">
      <div class="card-label">Accepted Shares</div>
      <div class="card-value" id="accepted">–</div>
      <div class="card-sub" id="rejected-sub">– rejected</div>
    </div>
    <div class="card card-yellow">
      <div class="card-label">Shares / Min</div>
      <div class="card-value" id="shares-min">–</div>
      <div class="card-sub">last 60 seconds</div>
    </div>
    <div class="card">
      <div class="card-label">Round Luck</div>
      <div class="card-value" id="round-luck">–</div>
      <div class="card-sub">accepted / expected</div>
    </div>
    <div class="card card-accent2">
      <div class="card-label">Wallet Balance</div>
      <div class="card-value" id="wallet-bal-card">–</div>
      <div class="card-sub">spendable ETHII</div>
    </div>
    <div class="card card-red">
      <div class="card-label">Stratum Port</div>
      <div class="card-value" id="stratum-port">–</div>
      <div class="card-sub">GPU miner port</div>
    </div>
  </div>

  <!-- ── Charts row ─────────────────────────────────────────────────────── -->
  <div class="grid-2">
    <div class="panel" style="margin-bottom:0">
      <div class="panel-header">Pool Hashrate History <span class="badge" id="hr-badge">–</span></div>
      <div class="chart-wrap"><canvas id="chartPoolHr"></canvas></div>
    </div>
    <div class="panel" style="margin-bottom:0">
      <div class="panel-header">
        Miner Hashrate History
        <select id="miner-selector" onchange="fetchMinerHistory(this.value)" style="background:var(--surface2);border:1px solid var(--border);color:var(--text);padding:3px 8px;border-radius:6px;font-size:12px;max-width:160px"></select>
      </div>
      <div class="chart-wrap"><canvas id="chartMinerHr"></canvas></div>
    </div>
  </div>

  <!-- ── Active Miners + System Health / Daemon / Payout ────────────────── -->
  <div class="grid-3">
    <div class="panel" style="margin-bottom:0">
      <div class="panel-header">Active Miners <span class="badge" id="miners-badge">–</span></div>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>Worker</th><th>Hashrate</th><th>Accepted</th><th>Rejected</th><th>Last Seen</th></tr></thead>
          <tbody id="miners-tbody"><tr><td colspan="5" class="empty">Waiting for miners…</td></tr></tbody>
        </table>
      </div>
    </div>

    <div>
      <!-- System Health -->
      <div class="panel" style="margin-bottom:12px">
        <div class="panel-header">System Health</div>
        <div class="panel-body">
          <div class="health-row"><span class="health-label">Node RPC</span><span class="health-val" id="h-node">–</span></div>
          <div class="health-row"><span class="health-label">Reward Address</span><span class="health-val mono" id="h-etherbase" style="font-size:11px;color:var(--accent2)">–</span></div>
          <div class="health-row"><span class="health-label">Block Height</span><span class="health-val" id="h-height">–</span></div>
          <div class="health-row"><span class="health-label">Peers</span><span class="health-val" id="h-peers">–</span></div>
          <div class="health-row"><span class="health-label">Stratum</span><span class="health-val health-ok" id="h-stratum">–</span></div>
          <div class="health-row"><span class="health-label">Miners</span><span class="health-val" id="h-miners">–</span></div>
          <div class="health-row"><span class="health-label">Accepted</span><span class="health-val health-ok" id="h-accepted">–</span></div>
          <div class="health-row"><span class="health-label">Rejected</span><span class="health-val" id="h-rejected">–</span></div>
          <div class="health-row" style="border-bottom:none"><span class="health-label">Uptime</span><span class="health-val" id="h-uptime">–</span></div>
        </div>
      </div>

      <!-- Daemon Updates -->
      <div class="panel" style="margin-bottom:12px">
        <div class="panel-header">Daemon Updates</div>
        <div class="panel-body">
          <div class="health-row"><span class="health-label">Node Version</span><span class="health-val mono" id="d-node-ver" style="font-size:11px;color:var(--accent2)">–</span></div>
          <div class="health-row"><span class="health-label">Stratum</span><span class="health-val" style="color:var(--accent2)">v1.0.0</span></div>
          <div class="health-row" style="border-bottom:none">
            <span class="health-label">Update Check</span>
            <span class="health-val health-warn" id="d-update-msg">–</span>
          </div>
        </div>
      </div>

      <!-- Payout Settings -->
      <div class="panel" style="margin-bottom:0">
        <div class="panel-header">Payout Settings</div>
        <div class="panel-body">
          <div class="form-row">
            <label>Mining Address</label>
            <input type="text" id="payout-address" placeholder="0x…" style="font-size:11px">
          </div>
          <div class="form-row" style="margin-bottom:10px">
            <button class="btn" onclick="savePayoutAddress()" style="font-size:11px;padding:5px 12px">Save Address</button>
            <button class="btn-outline" onclick="generateAddress()" style="font-size:11px;padding:5px 10px">Generate From Wallet</button>
          </div>
          <div class="form-row">
            <label>Min Payment</label>
            <input type="number" id="payout-min" placeholder="0.1" step="0.1" min="0" style="max-width:100px">
            <button class="btn" onclick="saveMinPayment()" style="font-size:11px;padding:5px 10px">Save</button>
          </div>
          <div id="payout-msg" style="font-size:11px;color:var(--green);margin-top:6px"></div>
        </div>
      </div>
    </div>
  </div>

  <!-- ── Worker Labels ──────────────────────────────────────────────────── -->
  <div class="panel">
    <div class="panel-header">Worker Labels <span class="badge" id="workers-badge">–</span></div>
    <div style="overflow-x:auto">
      <table>
        <thead><tr><th>Worker Name</th><th>Label</th><th>Status</th><th>Hashrate</th><th>Blocks Found</th></tr></thead>
        <tbody id="workers-tbody"><tr><td colspan="5" class="empty">No workers tracked yet</td></tr></tbody>
      </table>
    </div>
    <div class="panel-body" style="border-top:1px solid var(--border)">
      <div class="form-row">
        <label>Worker</label>
        <input type="text" id="wl-worker" placeholder="worker name" style="max-width:180px">
        <label style="min-width:50px">Label</label>
        <input type="text" id="wl-label" placeholder="e.g. Rig 1 - GPU Farm">
        <button class="btn" onclick="saveWorkerLabel()">Save Label</button>
      </div>
      <div style="font-size:11px;color:var(--muted)">Workers are automatically detected when miners connect. Add a label to name your rigs for easy tracking.</div>
    </div>
  </div>

  <!-- ── Blocks Found + Payments ────────────────────────────────────────── -->
  <div class="grid-2">
    <div class="panel" style="margin-bottom:0">
      <div class="panel-header">Blocks Found <span class="badge" id="blocks-badge">0</span></div>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>#</th><th>Worker</th><th>Block</th><th>Time</th><th>Reward</th></tr></thead>
          <tbody id="blocks-tbody"><tr><td colspan="5" class="empty">No blocks found yet — keep mining!</td></tr></tbody>
        </table>
      </div>
    </div>
    <div class="panel" style="margin-bottom:0">
      <div class="panel-header">Payments <span class="badge">Solo — direct to wallet</span></div>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>Address</th><th>Amount</th><th>Block</th><th>Time</th></tr></thead>
          <tbody id="payments-tbody"><tr><td colspan="4" class="empty">Rewards go directly to your mining address</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- ── Wallet Manager ─────────────────────────────────────────────────── -->
  <div class="panel">
    <div class="panel-header">Wallet Manager</div>
    <div class="panel-body">
      <div style="font-size:12px;color:var(--muted);margin-bottom:10px">Mining Address: <span id="wm-address" class="mono" style="color:var(--accent)">–</span></div>
      <div class="balance-grid">
        <div class="bal-box">
          <div class="bal-label">Spendable Balance</div>
          <div class="bal-val" id="wm-balance">–</div>
          <div style="font-size:10px;color:var(--muted);margin-top:3px">ETHII</div>
        </div>
        <div class="bal-box">
          <div class="bal-label">Pending (incl. immature)</div>
          <div class="bal-val" id="wm-pending" style="color:var(--yellow)">–</div>
          <div style="font-size:10px;color:var(--muted);margin-top:3px">ETHII</div>
        </div>
        <div class="bal-box">
          <div class="bal-label">Session Mined</div>
          <div class="bal-val" id="wm-total-mined" style="color:var(--orange)">–</div>
          <div style="font-size:10px;color:var(--muted);margin-top:3px">ETHII</div>
        </div>
      </div>

      <div style="font-weight:600;font-size:13px;margin-bottom:10px">Recent Activity</div>
      <div style="overflow-x:auto;margin-bottom:18px">
        <table>
          <thead><tr><th>Type</th><th>Amount</th><th>Block</th><th>Time</th></tr></thead>
          <tbody id="wm-txs-tbody"><tr><td colspan="4" class="empty">No activity yet</td></tr></tbody>
        </table>
      </div>

      <div style="font-weight:600;font-size:13px;margin-bottom:10px;border-top:1px solid var(--border);padding-top:14px">Send ETHII</div>
      <div class="form-row">
        <label>From</label>
        <select id="send-from" style="max-width:320px;font-size:11px"></select>
      </div>
      <div class="form-row">
        <label>To Address</label>
        <input type="text" id="send-to" placeholder="0x…">
      </div>
      <div class="form-row">
        <label>Amount</label>
        <input type="number" id="send-amount" placeholder="0.0" step="0.001" min="0" style="max-width:140px">
        <span style="color:var(--muted);font-size:12px">ETHII</span>
      </div>
      <div class="form-row">
        <label>Password</label>
        <input type="password" id="send-password" placeholder="wallet password" style="max-width:200px">
        <button class="btn btn-green" onclick="sendETHII()">Send</button>
      </div>
      <div id="send-msg" style="font-size:12px;margin-top:6px;min-height:18px"></div>
    </div>
  </div>

  <!-- ── Share Monitor ──────────────────────────────────────────────────── -->
  <div class="panel">
    <div class="panel-header">
      Share Monitor
      <button class="btn" id="sm-toggle" onclick="toggleShareMonitor()">Show</button>
    </div>
    <div class="sm-wrap" id="sm-wrap">
      <div class="share-monitor" id="sm-feed"></div>
    </div>
  </div>

</main>

<footer>
  <div>ETHII &bull; ETH 2.0 Proof of Work &bull; Chain ID 2048 &bull; Ethash Algorithm</div>
  <div style="margin-top:5px">by <a href="https://www.youtube.com/@BitsPleaseYT" target="_blank">BitsPleaseYT</a></div>
</footer>

<script>
// ─── Charts ───────────────────────────────────────────────────────────────────
var poolHrHistory = [];
var chartPoolHr, chartMinerHR;
var smOpen = false;
var lastShareCount = 0;
var currentMinerWorker = '';

function makeLineChart(id, label, color) {
  var ctx = document.getElementById(id);
  if (!ctx || !window.Chart) return null;
  return new Chart(ctx, {
    type: 'line',
    data: { datasets: [{ label: label, data: [], borderColor: color, backgroundColor: color.replace('rgb(', 'rgba(').replace(')', ',0.08)'), borderWidth: 2, pointRadius: 0, tension: 0.3, fill: true }] },
    options: {
      responsive: true, maintainAspectRatio: false, animation: false,
      scales: {
        x: { type: 'time', time: { unit: 'minute' }, grid: { color: '#1e2d40' }, ticks: { color: '#6b8299', maxTicksLimit: 6 } },
        y: { grid: { color: '#1e2d40' }, ticks: { color: '#6b8299' }, beginAtZero: true }
      },
      plugins: { legend: { display: false } }
    }
  });
}

function makeMinerHRChart(id) {
  var ctx = document.getElementById(id);
  if (!ctx || !window.Chart) return null;
  return new Chart(ctx, {
    type: 'bar',
    data: {
      datasets: [
        { label: 'Hashrate MH/s', data: [], backgroundColor: 'rgba(255,140,0,0.65)', borderColor: '#ff8c00', borderWidth: 1 },
        { type: 'scatter', label: 'Block Found', data: [], backgroundColor: '#00d4ff', borderColor: '#ffffff', pointStyle: 'star', pointRadius: 12, pointHoverRadius: 15, showLine: false }
      ]
    },
    options: {
      responsive: true, maintainAspectRatio: false, animation: false,
      scales: {
        x: { type: 'time', time: { unit: 'minute' }, grid: { color: '#1e2d40' }, ticks: { color: '#6b8299', maxTicksLimit: 6 } },
        y: { grid: { color: '#1e2d40' }, ticks: { color: '#6b8299' }, beginAtZero: true }
      },
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: function(ctx) { return ctx.datasetIndex === 1 ? 'Block #' + (ctx.raw.blockNum || '') : fmtHR(ctx.raw.y || ctx.raw); } } } }
    }
  });
}

function initCharts() {
  chartPoolHr  = makeLineChart('chartPoolHr', 'Pool MH/s', 'rgb(0,212,255)');
  chartMinerHR = makeMinerHRChart('chartMinerHr');
}

// ─── Formatters ───────────────────────────────────────────────────────────────
function fmtHR(mhs) {
  if (!mhs || mhs <= 0) return '0 H/s';
  if (mhs >= 1000) return (mhs / 1000).toFixed(2) + ' GH/s';
  if (mhs >= 1)    return mhs.toFixed(2) + ' MH/s';
  if (mhs >= 0.001) return (mhs * 1000).toFixed(2) + ' KH/s';
  return (mhs * 1e6).toFixed(0) + ' H/s';
}
function fmtDiff(hexDiff) {
  if (!hexDiff || hexDiff === '0x0' || hexDiff === '0x') return '–';
  try {
    var n = BigInt(hexDiff);
    if (n >= BigInt('1000000000000')) return (Number(n) / 1e12).toFixed(2) + ' T';
    if (n >= BigInt('1000000000'))    return (Number(n) / 1e9).toFixed(2) + ' G';
    if (n >= BigInt('1000000'))       return (Number(n) / 1e6).toFixed(2) + ' M';
    if (n >= BigInt('1000'))          return (Number(n) / 1e3).toFixed(2) + ' K';
    return n.toString();
  } catch(e) { return hexDiff; }
}
function fmtUptime(sec) {
  var d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
  if (h > 0) return h + 'h ' + m + 'm ' + s + 's';
  if (m > 0) return m + 'm ' + s + 's';
  return s + 's';
}
function fmtTime(iso) { try { return new Date(iso).toLocaleTimeString(); } catch(e) { return iso; } }
function fmtDate(iso) { try { return new Date(iso).toLocaleString(); } catch(e) { return iso; } }
function timeSince(iso) {
  try {
    var diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
    if (diff < 60) return diff + 's ago';
    if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
    return Math.floor(diff / 3600) + 'h ago';
  } catch(e) { return '–'; }
}
function setText(id, val) { var el = document.getElementById(id); if (el) el.textContent = val; }
function truncAddr(a) { if (!a || a.length < 12) return a || '–'; return a.slice(0,8) + '…' + a.slice(-6); }

// ─── Stats ────────────────────────────────────────────────────────────────────
function fetchStats() {
  fetch('/api/stats').then(function(r) { return r.json(); }).then(function(d) {
    var p = d.pool, n = d.network;
    var now = new Date();
    poolHrHistory.push({ x: now, y: p.hashrate });
    if (poolHrHistory.length > 120) poolHrHistory.shift();
    if (chartPoolHr) { chartPoolHr.data.datasets[0].data = poolHrHistory.slice(); chartPoolHr.update('none'); }
    document.getElementById('hr-badge').textContent = fmtHR(p.hashrate);

    setText('pool-hr', fmtHR(p.hashrate));
    setText('pool-miners', p.miners + ' miner' + (p.miners !== 1 ? 's' : '') + ' connected');
    setText('net-hr', fmtHR(n.hashrate));
    setText('net-diff', fmtDiff(n.difficulty));
    setText('net-peers', n.peers + ' peer' + (n.peers !== 1 ? 's' : ''));
    setText('block-height', n.blockHeight > 0 ? '#' + n.blockHeight.toLocaleString() : '–');
    setText('blocks-found', p.blocksFound);
    setText('total-mined', p.totalMined ? p.totalMined.toFixed(1) + ' E2' : '0');
    setText('accepted', p.accepted);
    setText('rejected-sub', p.rejected + ' rejected');
    setText('stratum-port', p.stratumPort);
    setText('shares-min', p.sharesPerMin ? p.sharesPerMin.toFixed(1) : '0');
    if (p.roundLuck > 0) {
      var luckEl = document.getElementById('round-luck');
      luckEl.textContent = p.roundLuck.toFixed(0) + '%';
      luckEl.style.color = p.roundLuck > 100 ? 'var(--green)' : p.roundLuck > 50 ? 'var(--yellow)' : 'var(--red)';
    }
    setText('uptime-val', fmtUptime(d.uptime));
    setText('uptime-badge', 'up ' + fmtUptime(d.uptime));

    setText('h-node', n.nodeUp ? 'Online' : 'Offline');
    document.getElementById('h-node').className = 'health-val ' + (n.nodeUp ? 'health-ok' : 'health-err');
    if (p.etherbase) {
      var eb = document.getElementById('h-etherbase');
      if (eb) { eb.textContent = p.etherbase.slice(0,10) + '…' + p.etherbase.slice(-6); eb.title = p.etherbase; }
    }
    setText('h-height', n.blockHeight > 0 ? '#' + n.blockHeight.toLocaleString() : '–');
    setText('h-peers', n.peers);
    setText('h-stratum', ':' + p.stratumPort);
    setText('h-miners', p.miners);
    setText('h-accepted', p.accepted);
    setText('h-rejected', p.rejected);
    document.getElementById('h-rejected').className = 'health-val ' + (p.rejected > 0 ? 'health-warn' : 'health-ok');
    setText('h-uptime', fmtUptime(d.uptime));

    var dot = document.getElementById('node-dot');
    dot.className = 'status-dot' + (n.nodeUp ? '' : ' red');
    setText('node-txt', n.nodeUp ? 'Node Online' : 'Node Offline');
    setText('last-refresh', 'Updated ' + now.toLocaleTimeString());
  }).catch(function() { setText('last-refresh', 'Refresh failed'); });
}

// ─── Miners ───────────────────────────────────────────────────────────────────
function fetchMiners() {
  fetch('/api/miners').then(function(r) { return r.json(); }).then(function(miners) {
    var tbody = document.getElementById('miners-tbody');
    document.getElementById('miners-badge').textContent = miners.length;
    if (miners.length === 0) { tbody.innerHTML = '<tr><td colspan="5" class="empty">No miners connected</td></tr>'; return; }
    var html = '';
    miners.forEach(function(m) {
      html += '<tr>' +
        '<td class="mono">' + (m.worker || '–') + '</td>' +
        '<td style="color:var(--accent)">' + fmtHR(m.hashrate) + '</td>' +
        '<td style="color:var(--green)">' + m.accepted + '</td>' +
        '<td style="color:' + (m.rejected > 0 ? 'var(--red)' : 'var(--muted)') + '">' + m.rejected + '</td>' +
        '<td style="color:var(--muted)">' + timeSince(m.lastSeen) + '</td>' +
        '</tr>';
    });
    tbody.innerHTML = html;
  });
}

// ─── Blocks ───────────────────────────────────────────────────────────────────
function fetchBlocks() {
  fetch('/api/blocks').then(function(r) { return r.json(); }).then(function(blocks) {
    var tbody = document.getElementById('blocks-tbody');
    var badge = document.getElementById('blocks-badge');
    badge.textContent = blocks.length;
    if (blocks.length === 0) { tbody.innerHTML = '<tr><td colspan="5" class="empty">No blocks found yet — keep mining!</td></tr>'; return; }
    var html = '';
    blocks.forEach(function(b, i) {
      html += '<tr>' +
        '<td style="color:var(--muted)">' + (blocks.length - i) + '</td>' +
        '<td class="mono" style="color:var(--accent)">' + (b.worker || 'local') + '</td>' +
        '<td style="color:var(--accent2)">' + (b.blockNum > 0 ? '#' + b.blockNum.toLocaleString() : '–') + '</td>' +
        '<td style="color:var(--muted)">' + fmtTime(b.at) + '</td>' +
        '<td style="color:var(--green);font-weight:600">' + b.reward.toFixed(1) + ' ETHII</td>' +
        '</tr>';
    });
    tbody.innerHTML = html;

    // Also update payments table
    var ptbody = document.getElementById('payments-tbody');
    if (ptbody) {
      if (blocks.length === 0) { ptbody.innerHTML = '<tr><td colspan="4" class="empty">Rewards go directly to your mining address</td></tr>'; return; }
      var ph = '';
      blocks.forEach(function(b) {
        ph += '<tr>' +
          '<td><span class="mono addr" style="color:var(--muted)">' + (b.worker || 'solo') + '</span></td>' +
          '<td style="color:var(--green);font-weight:600">' + b.reward.toFixed(1) + ' ETHII</td>' +
          '<td style="color:var(--accent2)">' + (b.blockNum > 0 ? '#' + b.blockNum.toLocaleString() : '–') + '</td>' +
          '<td style="color:var(--muted)">' + fmtTime(b.at) + '</td>' +
          '</tr>';
      });
      ptbody.innerHTML = ph;
    }
  });
}

// ─── Miner HR History ─────────────────────────────────────────────────────────
function fetchMinerHistory(worker) {
  currentMinerWorker = worker || '';
  var url = '/api/miner-history' + (currentMinerWorker ? '?worker=' + encodeURIComponent(currentMinerWorker) : '');
  fetch(url).then(function(r) { return r.json(); }).then(function(d) {
    // Update worker selector
    var sel = document.getElementById('miner-selector');
    if (sel && d.workers && d.workers.length > 0) {
      var cur = sel.value || d.worker;
      var opts = '<option value="">All</option>';
      d.workers.forEach(function(w) { opts += '<option value="' + w + '"' + (w === cur ? ' selected' : '') + '>' + w + '</option>'; });
      sel.innerHTML = opts;
      if (!sel.value && d.worker) sel.value = d.worker;
    }
    if (!chartMinerHR) return;
    var barData = (d.samples || []).map(function(s) { return { x: new Date(s.t), y: s.hr }; });
    var maxHR = 1;
    barData.forEach(function(p) { if (p.y > maxHR) maxHR = p.y; });
    var starData = (d.blocks || []).map(function(b) { return { x: new Date(b.t), y: maxHR * 0.85, blockNum: b.n }; });
    chartMinerHR.data.datasets[0].data = barData;
    chartMinerHR.data.datasets[1].data = starData;
    chartMinerHR.update('none');
  });
}

// ─── Worker Labels ────────────────────────────────────────────────────────────
function fetchWorkerLabels() {
  fetch('/api/worker-labels').then(function(r) { return r.json(); }).then(function(d) {
    var rows = d.workers || [];
    var tbody = document.getElementById('workers-tbody');
    document.getElementById('workers-badge').textContent = rows.length;
    if (rows.length === 0) { tbody.innerHTML = '<tr><td colspan="5" class="empty">No workers tracked yet</td></tr>'; return; }
    var html = '';
    rows.forEach(function(w) {
      var statusCls = w.status === 'online' ? 'worker-status-on' : 'worker-status-off';
      var statusDot = w.status === 'online' ? '&#9679;' : '&#9675;';
      html += '<tr>' +
        '<td class="mono" style="color:var(--accent)">' + (w.worker || '–') + '</td>' +
        '<td>' + (w.label || '<span style="color:var(--muted);font-style:italic">no label</span>') + '</td>' +
        '<td><span class="' + statusCls + '">' + statusDot + ' ' + (w.status || '–') + '</span></td>' +
        '<td style="color:var(--orange)">' + fmtHR(w.hashrate) + '</td>' +
        '<td style="color:var(--accent2)">' + (w.blocksFound || 0) + '</td>' +
        '</tr>';
    });
    tbody.innerHTML = html;
    // Populate worker dropdown in label form
    var wlWorker = document.getElementById('wl-worker');
    if (wlWorker && !wlWorker.value) {
      if (rows.length > 0 && rows[0].status === 'online') wlWorker.placeholder = rows[0].worker;
    }
  });
}

function saveWorkerLabel() {
  var worker = document.getElementById('wl-worker').value.trim();
  var label = document.getElementById('wl-label').value.trim();
  if (!worker) return;
  fetch('/api/worker-labels', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ worker: worker, label: label }) })
    .then(function() { fetchWorkerLabels(); document.getElementById('wl-worker').value = ''; document.getElementById('wl-label').value = ''; });
}

// ─── Daemon Version ───────────────────────────────────────────────────────────
function fetchDaemonVersion() {
  fetch('/api/daemon-version').then(function(r) { return r.json(); }).then(function(d) {
    setText('d-node-ver', d.nodeVersion || '–');
    setText('d-update-msg', d.updateMessage || 'unavailable');
  });
}

// ─── Payout Settings ──────────────────────────────────────────────────────────
function fetchPayoutSettings() {
  fetch('/api/payout').then(function(r) { return r.json(); }).then(function(d) {
    if (d.miningAddress) document.getElementById('payout-address').value = d.miningAddress;
    if (d.minPayment) document.getElementById('payout-min').value = d.minPayment;
  });
}

function savePayoutAddress() {
  var addr = document.getElementById('payout-address').value.trim();
  fetch('/api/payout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ miningAddress: addr }) })
    .then(function() { document.getElementById('payout-msg').textContent = 'Address saved'; setTimeout(function() { setText('payout-msg', ''); }, 3000); });
}

function saveMinPayment() {
  var mp = parseFloat(document.getElementById('payout-min').value);
  if (isNaN(mp) || mp < 0) return;
  fetch('/api/payout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ minPayment: mp }) })
    .then(function() { document.getElementById('payout-msg').textContent = 'Min payment saved'; setTimeout(function() { setText('payout-msg', ''); }, 3000); });
}

function generateAddress() {
  var pw = prompt('Enter a password for the new wallet address:');
  if (!pw) return;
  fetch('/api/wallet/generate-address', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: pw }) })
    .then(function(r) { return r.json(); }).then(function(d) {
      if (d.address) {
        document.getElementById('payout-address').value = d.address;
        document.getElementById('payout-msg').textContent = 'New address generated: ' + d.address;
        savePayoutAddress();
      } else {
        document.getElementById('payout-msg').textContent = 'Error: ' + (d.error || 'unknown');
      }
    });
}

// ─── Wallet Manager ───────────────────────────────────────────────────────────
function fetchWallet() {
  fetch('/api/wallet').then(function(r) { return r.json(); }).then(function(d) {
    setText('wm-address', d.address || '–');
    document.getElementById('wm-address').title = d.address || '';
    setText('wm-balance', d.balance ? d.balance.toFixed(4) : '0.0000');
    setText('wm-pending', d.pending ? d.pending.toFixed(4) : '0.0000');
    setText('wm-total-mined', d.totalMined ? d.totalMined.toFixed(1) : '0.0');
    setText('wallet-bal-card', d.balance ? d.balance.toFixed(2) : '–');

    // Populate from accounts
    var sel = document.getElementById('send-from');
    if (sel && d.allAccounts) {
      var opts = '';
      d.allAccounts.forEach(function(a) { opts += '<option value="' + a + '">' + a + '</option>'; });
      sel.innerHTML = opts || '<option value="">No accounts</option>';
    }

    // TX table
    var tbody = document.getElementById('wm-txs-tbody');
    if (!d.txs || d.txs.length === 0) { tbody.innerHTML = '<tr><td colspan="4" class="empty">No activity yet</td></tr>'; return; }
    var html = '';
    d.txs.forEach(function(tx) {
      html += '<tr>' +
        '<td><span class="tag tag-ok">' + tx.type + '</span></td>' +
        '<td style="color:var(--green);font-weight:600">+' + tx.amount.toFixed(1) + ' ETHII</td>' +
        '<td style="color:var(--accent2)">' + (tx.block > 0 ? '#' + tx.block.toLocaleString() : '–') + '</td>' +
        '<td style="color:var(--muted)">' + fmtTime(tx.at) + '</td>' +
        '</tr>';
    });
    tbody.innerHTML = html;
  });
}

function sendETHII() {
  var to = document.getElementById('send-to').value.trim();
  var amount = parseFloat(document.getElementById('send-amount').value);
  var password = document.getElementById('send-password').value;
  var from = document.getElementById('send-from').value;
  var msgEl = document.getElementById('send-msg');
  if (!to || isNaN(amount) || amount <= 0) { msgEl.style.color = 'var(--red)'; msgEl.textContent = 'Please enter a valid address and amount.'; return; }
  msgEl.style.color = 'var(--muted)'; msgEl.textContent = 'Sending…';
  fetch('/api/wallet/send', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ from: from, to: to, amount: amount, password: password }) })
    .then(function(r) { return r.json(); }).then(function(d) {
      if (d.txHash) {
        msgEl.style.color = 'var(--green)';
        msgEl.textContent = 'Sent! TX: ' + d.txHash;
        document.getElementById('send-to').value = '';
        document.getElementById('send-amount').value = '';
        document.getElementById('send-password').value = '';
        setTimeout(fetchWallet, 3000);
      } else {
        msgEl.style.color = 'var(--red)';
        msgEl.textContent = 'Error: ' + (d.error || 'unknown error');
      }
    });
}

// ─── Shares ───────────────────────────────────────────────────────────────────
function fetchShares() {
  if (!smOpen) return;
  fetch('/api/shares').then(function(r) { return r.json(); }).then(function(shares) {
    if (shares.length === lastShareCount) return;
    lastShareCount = shares.length;
    var feed = document.getElementById('sm-feed');
    var html = '';
    shares.forEach(function(s) {
      html += '<div class="sm-row">' +
        '<span class="sm-time">' + fmtTime(s.at) + '</span>' +
        '<span class="sm-worker">' + (s.worker || 'anon') + '</span>' +
        '<span class="' + (s.valid ? 'sm-valid' : 'sm-invalid') + '">' + (s.valid ? 'ACCEPTED' : 'REJECTED') + '</span>' +
        '</div>';
    });
    feed.innerHTML = html;
  });
}

function toggleShareMonitor() {
  smOpen = !smOpen;
  var wrap = document.getElementById('sm-wrap');
  var btn = document.getElementById('sm-toggle');
  wrap.className = 'sm-wrap' + (smOpen ? ' open' : '');
  btn.className = 'btn' + (smOpen ? ' active' : '');
  btn.textContent = smOpen ? 'Hide' : 'Show';
  if (smOpen) fetchShares();
}

// ─── Init ─────────────────────────────────────────────────────────────────────
window.addEventListener('load', function() {
  initCharts();
  fetchStats();
  fetchMiners();
  fetchBlocks();
  fetchMinerHistory('');
  fetchWorkerLabels();
  fetchDaemonVersion();
  fetchPayoutSettings();
  fetchWallet();

  setInterval(function() {
    fetchStats();
    fetchMiners();
    fetchBlocks();
    fetchMinerHistory(currentMinerWorker);
    fetchShares();
  }, 5000);

  setInterval(function() {
    fetchWorkerLabels();
    fetchWallet();
    fetchDaemonVersion();
  }, 30000);
});
</script>
</body>
</html>`
