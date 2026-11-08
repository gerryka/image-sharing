// Command vectors erzeugt feste Testvektoren für ImgShare-Clients
// (HKDF-Ableitung, Sicherheitscode, Base32, AES-GCM mit fester Nonce).
// Unabhängige Referenz in Go-Standardkrypto, siehe docs/PROTOCOL.md.
//
//	go run ./tools/vectors > client-mac/Tests/ImgShareCoreTests/Resources/vectors.json
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type vector struct {
	RootKeyHex    string `json:"root_key_hex"`
	EncKeyHex     string `json:"enc_key_hex"`
	RoomID        string `json:"room_id"`
	TokenHex      string `json:"token_hex"`
	TokenB64URL   string `json:"token_b64url"`
	SafetyCode    string `json:"safety_code"`
	Base32        string `json:"base32"`
	NonceHex      string `json:"nonce_hex"`
	PlaintextUTF8 string `json:"plaintext_utf8"`
	CiphertextHex string `json:"ciphertext_hex"`
}

var salt = []byte("imgshare-v1")

func kdf(root []byte, info string, n int) []byte {
	out, err := hkdf.Key(sha256.New, root, salt, info, n)
	if err != nil {
		panic(err)
	}
	return out
}

func groups(s string) string {
	var parts []string
	for i := 0; i < len(s); i += 4 {
		parts = append(parts, s[i:min(i+4, len(s))])
	}
	return strings.Join(parts, "-")
}

func make1(root []byte) vector {
	enc := kdf(root, "enc", 32)
	room := hex.EncodeToString(kdf(root, "room", 16))
	token := kdf(root, "auth", 32)
	n := binary.LittleEndian.Uint64(kdf(root, "safety", 8)) % 1_000_000_000_000
	s := fmt.Sprintf("%012d", n)
	safety := s[0:3] + " " + s[3:6] + " · " + s[6:9] + " " + s[9:12]

	nonce := make([]byte, 12)
	for i := range nonce {
		nonce[i] = byte(0xa0 + i)
	}
	plain := `{"v":1,"kind":"text","text":"Grüße 👋"}`
	block, _ := aes.NewCipher(enc)
	gcm, _ := cipher.NewGCM(block)
	ct := gcm.Seal(append([]byte{}, nonce...), nonce, []byte(plain), []byte(room))

	return vector{
		RootKeyHex:    hex.EncodeToString(root),
		EncKeyHex:     hex.EncodeToString(enc),
		RoomID:        room,
		TokenHex:      hex.EncodeToString(token),
		TokenB64URL:   base64.RawURLEncoding.EncodeToString(token),
		SafetyCode:    safety,
		Base32:        groups(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(root)),
		NonceHex:      hex.EncodeToString(nonce),
		PlaintextUTF8: plain,
		CiphertextHex: hex.EncodeToString(ct),
	}
}

func main() {
	a := make([]byte, 32)
	b := make([]byte, 32)
	for i := range a {
		a[i] = byte(i)
		b[i] = 0xff
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode([]vector{make1(a), make1(b)}); err != nil {
		panic(err)
	}
}
