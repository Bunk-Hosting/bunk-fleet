package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// persistedState is the on-disk state the agent reuses across restarts: the
// enrollment credentials plus the customer network it was assigned, so a reboot
// keeps the same node identity and reconfigures the same bridge without
// re-enrolling.
type persistedState struct {
	NodeID        string `json:"node_id"`
	AgentToken    string `json:"agent_token"`
	VpsGateway    string `json:"vps_gateway,omitempty"`
	VpsCidrPrefix int    `json:"vps_cidr_prefix,omitempty"`
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
