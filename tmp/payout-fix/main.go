package main

import (
	"fmt"
	"os"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/crypto"
)

func main() {
	ks, err := os.ReadFile("pool-keystore.json")
	if err != nil {
		panic(err)
	}
	key, err := keystore.DecryptKey(ks, "ETHIIPOOL78$$")
	if err != nil {
		fmt.Println("DECRYPT FAILED:", err)
		os.Exit(1)
	}
	fmt.Println("DECRYPT OK, address:", crypto.PubkeyToAddress(key.PrivateKey.PublicKey).Hex())
}
