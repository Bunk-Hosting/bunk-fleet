// Package config loads bunk-agent configuration from command-line flags with
// environment-variable fallbacks. Flags take precedence over the environment;
// the environment takes precedence over built-in defaults.
package config

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"
)

// ProxmoxConfig holds the Proxmox VE connection parameters.
type ProxmoxConfig struct {
	Host        string
	Node        string
	TokenID     string
	TokenSecret string
	VerifySSL   bool
}

// Config is the fully-resolved agent configuration.
type Config struct {
	// ControlPlaneURL is the base URL the agent dials out to.
	ControlPlaneURL string
	// EnrollToken is the one-time enrollment token (optional once enrolled).
	EnrollToken string
	// Hypervisor selects the local backend; currently only "proxmox".
	Hypervisor string
	// Proxmox holds backend-specific settings.
	Proxmox ProxmoxConfig
	// HeartbeatInterval controls how often capacity is reported.
	HeartbeatInterval time.Duration
	// StateDir is where the agent persists its enrollment so it survives restarts.
	StateDir string
}

// envOr returns the environment variable named key, or def if unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// envBool parses a boolean environment variable, falling back to def.
func envBool(key string, def bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

// envDuration parses a duration environment variable, falling back to def.
func envDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}

// Load parses flags (with env fallbacks) and returns the resolved Config. It
// validates required fields and returns a descriptive error if any are missing
// or malformed.
func Load() (Config, error) {
	fs := flag.NewFlagSet("bunk-agent", flag.ContinueOnError)

	var (
		controlPlaneURL = fs.String("control-plane-url", envOr("BUNK_CONTROL_PLANE_URL", ""), "control plane base URL")
		enrollToken     = fs.String("enroll-token", envOr("BUNK_ENROLL_TOKEN", ""), "one-time enrollment token")
		hypervisor      = fs.String("hypervisor", envOr("BUNK_HYPERVISOR", "proxmox"), "local hypervisor backend (proxmox)")

		pveHost   = fs.String("proxmox-host", envOr("BUNK_PROXMOX_HOST", ""), "Proxmox VE API base URL (https://host:8006)")
		pveNode   = fs.String("proxmox-node", envOr("BUNK_PROXMOX_NODE", ""), "Proxmox VE node name")
		pveTokID  = fs.String("proxmox-token-id", envOr("BUNK_PROXMOX_TOKEN_ID", ""), "Proxmox API token id (USER@REALM!TOKENID)")
		pveSecret = fs.String("proxmox-token-secret", envOr("BUNK_PROXMOX_TOKEN_SECRET", ""), "Proxmox API token secret")
		// Verify TLS by default: the Proxmox API token is root-equivalent and must
		// not be sent over an unverified connection. Operators with self-signed
		// certs must explicitly opt out via BUNK_PROXMOX_VERIFY_SSL=false.
		pveVerify = fs.Bool("proxmox-verify-ssl", envBool("BUNK_PROXMOX_VERIFY_SSL", true), "verify Proxmox TLS certificate")

		heartbeat = fs.Duration("heartbeat-interval", envDuration("BUNK_HEARTBEAT_INTERVAL", 30*time.Second), "capacity heartbeat interval")

		stateDir = fs.String("state-dir", envOr("BUNK_STATE_DIR", "/var/lib/bunk-agent"), "directory for persisted enrollment state")
	)

	if err := fs.Parse(os.Args[1:]); err != nil {
		return Config{}, err
	}

	cfg := Config{
		ControlPlaneURL:   *controlPlaneURL,
		EnrollToken:       *enrollToken,
		Hypervisor:        *hypervisor,
		HeartbeatInterval: *heartbeat,
		StateDir:          *stateDir,
		Proxmox: ProxmoxConfig{
			Host:        *pveHost,
			Node:        *pveNode,
			TokenID:     *pveTokID,
			TokenSecret: *pveSecret,
			VerifySSL:   *pveVerify,
		},
	}

	if err := cfg.validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// validate checks required fields.
func (c Config) validate() error {
	if c.ControlPlaneURL == "" {
		return errors.New("config: control-plane-url is required")
	}
	if c.Hypervisor != "proxmox" {
		return fmt.Errorf("config: unsupported hypervisor %q (only \"proxmox\" is supported)", c.Hypervisor)
	}
	if c.Proxmox.Host == "" || c.Proxmox.Node == "" {
		return errors.New("config: proxmox-host and proxmox-node are required")
	}
	if c.Proxmox.TokenID == "" || c.Proxmox.TokenSecret == "" {
		return errors.New("config: proxmox-token-id and proxmox-token-secret are required")
	}
	if c.HeartbeatInterval <= 0 {
		return errors.New("config: heartbeat-interval must be positive")
	}
	return nil
}
