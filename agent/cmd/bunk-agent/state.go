package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// persistedState is the on-disk enrollment the agent reuses across restarts so a
// worker survives a reboot/recreate without consuming a fresh (single-use) token.
type persistedState struct {
	NodeID     string `json:"node_id"`
	AgentToken string `json:"agent_token"`
}

// loadState reads persisted enrollment credentials; ok is false when none exist.
func loadState(path string) (nodeID, agentToken string, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", "", false
	}
	var st persistedState
	if err := json.Unmarshal(b, &st); err != nil || st.NodeID == "" || st.AgentToken == "" {
		return "", "", false
	}
	return st.NodeID, st.AgentToken, true
}

// saveState writes enrollment credentials atomically with owner-only perms.
func saveState(path, nodeID, agentToken string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(persistedState{NodeID: nodeID, AgentToken: agentToken})
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
