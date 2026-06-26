package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// persistedState is the on-disk state the agent reuses across restarts: the
// enrollment credentials plus the WireGuard overlay keypair + assigned params,
// so a reboot keeps the same node identity AND the same overlay key the control
// plane already trusts.
type persistedState struct {
	NodeID       string `json:"node_id"`
	AgentToken   string `json:"agent_token"`
	WGPrivateKey string `json:"wg_private_key,omitempty"`
	WGPublicKey  string `json:"wg_public_key,omitempty"`
	HubPublicKey string `json:"hub_public_key,omitempty"`
	Endpoint     string `json:"endpoint,omitempty"`
	OverlayIP    string `json:"overlay_ip,omitempty"`
	OverlayCIDR  string `json:"overlay_cidr,omitempty"`
}

// loadState reads persisted state; ok is false when none (or incomplete) exist.
func loadState(path string) (persistedState, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return persistedState{}, false
	}
	var st persistedState
	if err := json.Unmarshal(b, &st); err != nil || st.NodeID == "" || st.AgentToken == "" {
		return persistedState{}, false
	}
	return st, true
}

// saveState writes the state atomically with owner-only perms.
func saveState(path string, st persistedState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
