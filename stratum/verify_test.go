package main

import (
	"bytes"
	"encoding/json"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

type rpcHeader struct {
	ParentHash  string `json:"parentHash"`
	Sha3Uncles  string `json:"sha3Uncles"`
	Miner       string `json:"miner"`
	StateRoot   string `json:"stateRoot"`
	TxRoot      string `json:"transactionsRoot"`
	ReceiptRoot string `json:"receiptsRoot"`
	LogsBloom   string `json:"logsBloom"`
	Difficulty  string `json:"difficulty"`
	Number      string `json:"number"`
	GasLimit    string `json:"gasLimit"`
	GasUsed     string `json:"gasUsed"`
	Timestamp   string `json:"timestamp"`
	ExtraData   string `json:"extraData"`
	MixHash     string `json:"mixHash"`
	Nonce       string `json:"nonce"`
	BaseFee     string `json:"baseFeePerGas"`
}

func hexBig(s string) *big.Int {
	b := new(big.Int)
	b.SetString(strings.TrimPrefix(s, "0x"), 16)
	return b
}

func TestVerifyRealBlock(t *testing.T) {
	body := `{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}`
	resp, err := http.Post("https://ethii.net/rpc", "application/json", bytes.NewBufferString(body))
	if err != nil {
		t.Skipf("RPC unreachable: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		Result rpcHeader `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	h := out.Result
	num := hexBig(h.Number)

	// Seal hash: keccak256(rlp(header fields without mixHash+nonce)),
	// baseFee included after extraData (London).
	fields := []interface{}{
		common.HexToHash(h.ParentHash),
		common.HexToHash(h.Sha3Uncles),
		common.HexToAddress(h.Miner),
		common.HexToHash(h.StateRoot),
		common.HexToHash(h.TxRoot),
		common.HexToHash(h.ReceiptRoot),
		common.FromHex(h.LogsBloom),
		hexBig(h.Difficulty),
		num,
		hexBig(h.GasLimit),
		hexBig(h.GasUsed),
		hexBig(h.Timestamp),
		common.FromHex(h.ExtraData),
	}
	if h.BaseFee != "" {
		fields = append(fields, hexBig(h.BaseFee))
	}
	enc, err := rlp.EncodeToBytes(fields)
	if err != nil {
		t.Fatalf("rlp: %v", err)
	}
	sealHash := crypto.Keccak256Hash(enc)

	nonce, err := strconv.ParseUint(strings.TrimPrefix(h.Nonce, "0x"), 16, 64)
	if err != nil {
		t.Fatalf("nonce: %v", err)
	}

	mixDigest, result := ethashHasher.Compute(num.Uint64(), sealHash, nonce)
	t.Logf("block=%d sealhash=%s", num.Uint64(), sealHash.Hex())
	t.Logf("chain mixHash   = %s", h.MixHash)
	t.Logf("computed mix    = %s", mixDigest.Hex())

	if !strings.EqualFold(mixDigest.Hex(), h.MixHash) {
		t.Fatalf("mix digest mismatch")
	}
	target := new(big.Int).Div(new(big.Int).Lsh(big.NewInt(1), 256), hexBig(h.Difficulty))
	r := new(big.Int).SetBytes(result.Bytes())
	if r.Cmp(target) > 0 {
		t.Fatalf("result above block target")
	}
	t.Logf("OK: result meets block target")
}
