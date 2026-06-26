package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestGenerateWGKey(t *testing.T) {
	priv, pub, err := generateWGKey()
	if err != nil {
		t.Fatalf("generateWGKey: %v", err)
	}
	for name, k := range map[string]string{"priv": priv, "pub": pub} {
		b, err := base64.StdEncoding.DecodeString(k)
		if err != nil || len(b) != 32 {
			t.Errorf("%s key invalid: %q (decoded len %d, err %v)", name, k, len(b), err)
		}
	}
	if priv == pub {
		t.Error("private and public key must differ")
	}

	// Distinct each call.
	priv2, _, _ := generateWGKey()
	if priv == priv2 {
		t.Error("expected a fresh key per call")
	}
}

func TestWGInterfaceConfig(t *testing.T) {
	conf := wgInterfaceConfig("PRIVKEY==", "10.99.0.5", "HUBPUB==", "vpn.example.com:51820")
	for _, want := range []string{
		"[Interface]",
		"PrivateKey = PRIVKEY==",
		"Address = 10.99.0.5/32",
		"[Peer]",
		"PublicKey = HUBPUB==",
		"Endpoint = vpn.example.com:51820",
		"AllowedIPs = 10.99.0.0/16",
		"PersistentKeepalive = 25",
	} {
		if !strings.Contains(conf, want) {
			t.Errorf("config missing %q\n---\n%s", want, conf)
		}
	}
}
