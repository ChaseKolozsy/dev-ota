package main

import (
	"crypto/rand"
	"crypto/rsa"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestIsLoopback(t *testing.T) {
	for _, host := range []string{"127.0.0.1", "::1", "localhost"} {
		if !isLoopback(host) {
			t.Errorf("expected %q to be loopback", host)
		}
	}
	if isLoopback("0.0.0.0") {
		t.Fatal("wildcard address must not be treated as loopback")
	}
}

func TestPersistentHostKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "host_key")
	first, err := loadOrCreateHostKey(path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := loadOrCreateHostKey(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(first.PublicKey().Marshal()) != string(second.PublicKey().Marshal()) {
		t.Fatal("host key changed between loads")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("host key mode = %o, want 600", info.Mode().Perm())
	}
}

func TestAuthorizedKeyCallback(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ssh.NewPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	allowed := map[string]struct{}{string(key.Marshal()): {}}
	if _, err := publicKeyCallback(allowed, false)(nil, key); err != nil {
		t.Fatalf("authorized key rejected: %v", err)
	}
	otherPrivateKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	other, _ := ssh.NewPublicKey(&otherPrivateKey.PublicKey)
	if _, err := publicKeyCallback(allowed, false)(nil, other); err == nil {
		t.Fatal("unauthorized key accepted")
	}
	if _, err := publicKeyCallback(nil, true)(nil, other); err != nil {
		t.Fatalf("accept-any-key rejected a key: %v", err)
	}
}
