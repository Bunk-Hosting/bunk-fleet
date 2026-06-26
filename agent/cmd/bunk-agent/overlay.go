package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/crypto/curve25519"
)

// generateWGKey creates a WireGuard (Curve25519) keypair, base64-encoded.
func generateWGKey() (priv, pub string, err error) {
	p := make([]byte, 32)
	if _, err = rand.Read(p); err != nil {
		return "", "", err
	}
	// Clamp per the X25519 spec.
	p[0] &= 248
	p[31] &= 127
	p[31] |= 64

	pubBytes, err := curve25519.X25519(p, curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(p), base64.StdEncoding.EncodeToString(pubBytes), nil
}

// wgInterfaceConfig renders the wg-quick config that joins this worker to the
// control-plane overlay hub. The whole overlay subnet routes through the hub.
func wgInterfaceConfig(privKey, overlayIP, hubPubKey, hubEndpoint string) string {
	return fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = %s/32

[Peer]
PublicKey = %s
Endpoint = %s
AllowedIPs = 10.99.0.0/16
PersistentKeepalive = 25
`, privKey, overlayIP, hubPubKey, hubEndpoint)
}

// applyOverlay writes the wg config and best-effort brings the interface up.
// Bring-up needs wireguard-tools + CAP_NET_ADMIN; failure is non-fatal (the
// config is on disk for the operator to apply).
func applyOverlay(logger *slog.Logger, st persistedState) {
	if st.WGPrivateKey == "" || st.OverlayIP == "" || st.HubPublicKey == "" {
		return
	}

	conf := wgInterfaceConfig(st.WGPrivateKey, st.OverlayIP, st.HubPublicKey, st.Endpoint)

	if err := os.MkdirAll("/etc/wireguard", 0o700); err != nil {
		logger.Warn("overlay: cannot create /etc/wireguard", "err", err)
		return
	}
	path := "/etc/wireguard/bunk0.conf"
	if err := os.WriteFile(path, []byte(conf), 0o600); err != nil {
		logger.Warn("overlay: cannot write config", "err", err)
		return
	}

	// Re-up idempotently (ignore a down failure when the iface is absent).
	_ = exec.CommandContext(context.Background(), "wg-quick", "down", "bunk0").Run()
	out, err := exec.CommandContext(context.Background(), "wg-quick", "up", "bunk0").CombinedOutput()
	if err != nil {
		logger.Info("overlay config written; bring-up skipped (need wireguard-tools + root)",
			"path", path, "detail", strings.TrimSpace(string(out)))
		return
	}
	logger.Info("overlay interface up", "ip", st.OverlayIP)
}
