package config

import (
	"strings"
	"testing"
	"time"
)

// The most consequential thing in this package is validateControlPlaneURL: plain
// http to a remote control plane lets anyone on the node's LAN take the agent
// token and, with it, dispatch commands to the hypervisor. Everything else here
// decides whether a typo in an env var fails loudly or quietly does the wrong
// thing.

func TestControlPlaneURLRequiresHTTPSForRemoteHosts(t *testing.T) {
	remote := []string{
		"http://app.bunkhosting.nl",
		"http://203.0.113.10",
		"http://app.bunkhosting.nl:8080/v1",
		"http://8.8.8.8:4000",
		// A public host that merely looks internal.
		"http://localhost.evil.example",
	}
	for _, raw := range remote {
		if err := validateControlPlaneURL(raw); err == nil {
			t.Errorf("validateControlPlaneURL(%q) allowed plain http to a remote host", raw)
		}
	}
}

func TestControlPlaneURLAllowsHTTPOnlyWhereNobodyCanSitBetween(t *testing.T) {
	internal := []string{
		"http://localhost:4000",
		"http://127.0.0.1:4000",
		"http://[::1]:4000",
		"http://10.10.0.5:4000",
		"http://192.168.1.70:4000",
		"http://172.16.4.9:4000",
		"http://169.254.1.1:4000",
		// A docker service name: one label, resolvable only inside the network.
		"http://bf-prod-cp:4000",
	}
	for _, raw := range internal {
		if err := validateControlPlaneURL(raw); err != nil {
			t.Errorf("validateControlPlaneURL(%q) = %v, want allowed", raw, err)
		}
	}
}

func TestControlPlaneURLAlwaysAllowsHTTPS(t *testing.T) {
	for _, raw := range []string{"https://app.bunkhosting.nl", "https://10.0.0.1:4000"} {
		if err := validateControlPlaneURL(raw); err != nil {
			t.Errorf("validateControlPlaneURL(%q) = %v", raw, err)
		}
	}
}

func TestControlPlaneURLRejectsOtherSchemes(t *testing.T) {
	// file:// and friends would be read by the HTTP client as something other
	// than a network call, and ws:// is not what this client speaks.
	for _, raw := range []string{"ftp://x", "file:///etc/passwd", "ws://app.bunkhosting.nl", "app.bunkhosting.nl"} {
		if err := validateControlPlaneURL(raw); err == nil {
			t.Errorf("validateControlPlaneURL(%q) was accepted", raw)
		}
	}
}

func TestIsInternalHost(t *testing.T) {
	cases := map[string]bool{
		"":                   false,
		"localhost":          true,
		"127.0.0.1":          true,
		"::1":                true,
		"10.0.0.1":           true,
		"172.31.255.254":     true,
		"192.168.0.1":        true,
		"169.254.169.254":    true,
		"bf-prod-cp":         true,
		"8.8.8.8":            false,
		"172.32.0.1":         false,
		"app.bunkhosting.nl": false,
	}
	for host, want := range cases {
		if got := isInternalHost(host); got != want {
			t.Errorf("isInternalHost(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestUnparseableEnvVarsAreFatalRatherThanDefaulted(t *testing.T) {
	// BUNK_ESXI_INSECURE=ture silently becoming false blocks every connection
	// with a confusing TLS error; BUNK_VPS_VLAN=1oo silently becoming untagged is
	// a tenant-isolation hazard. Both have to be loud.
	t.Run("bool", func(t *testing.T) {
		var errs []error
		if got := envBool("BUNK_TEST_BOOL", true, &errs); got != true {
			t.Errorf("envBool fell back to %v", got)
		}
		if len(errs) != 0 {
			t.Errorf("an unset var recorded an error: %v", errs)
		}

		t.Setenv("BUNK_TEST_BOOL", "ture")
		errs = nil
		envBool("BUNK_TEST_BOOL", true, &errs)
		if len(errs) != 1 || !strings.Contains(errs[0].Error(), "ture") {
			t.Errorf("errs = %v, want one mentioning the value", errs)
		}
	})

	t.Run("duration", func(t *testing.T) {
		var errs []error
		if got := envDuration("BUNK_TEST_DUR", 30*time.Second, &errs); got != 30*time.Second {
			t.Errorf("envDuration = %v", got)
		}

		t.Setenv("BUNK_TEST_DUR", "30")
		errs = nil
		envDuration("BUNK_TEST_DUR", 30*time.Second, &errs)
		if len(errs) != 1 {
			t.Errorf("a bare number was accepted as a duration: %v", errs)
		}

		t.Setenv("BUNK_TEST_DUR", "45s")
		errs = nil
		if got := envDuration("BUNK_TEST_DUR", 30*time.Second, &errs); got != 45*time.Second {
			t.Errorf("envDuration = %v, want 45s", got)
		}
		if len(errs) != 0 {
			t.Errorf("a valid duration recorded an error: %v", errs)
		}
	})

	t.Run("int", func(t *testing.T) {
		t.Setenv("BUNK_TEST_INT", "1oo")
		var errs []error
		envInt("BUNK_TEST_INT", 0, &errs)
		if len(errs) != 1 {
			t.Errorf("a typo'd integer was accepted: %v", errs)
		}
	})
}

func TestEnvOrFallsBackOnUnsetAndEmpty(t *testing.T) {
	if got := envOr("BUNK_TEST_STR", "fallback"); got != "fallback" {
		t.Errorf("envOr = %q", got)
	}
	// An empty value is treated as unset: an env var set to "" in a compose file
	// should not blank out a working default.
	t.Setenv("BUNK_TEST_STR", "")
	if got := envOr("BUNK_TEST_STR", "fallback"); got != "fallback" {
		t.Errorf("envOr with an empty value = %q", got)
	}
	t.Setenv("BUNK_TEST_STR", "set")
	if got := envOr("BUNK_TEST_STR", "fallback"); got != "set" {
		t.Errorf("envOr = %q", got)
	}
}

func base() Config {
	return Config{
		ControlPlaneURL:   "https://app.bunkhosting.nl",
		Hypervisor:        "proxmox",
		HeartbeatInterval: 30 * time.Second,
		Proxmox: ProxmoxConfig{
			Host: "https://10.0.0.5:8006", Node: "pve",
			TokenID: "root@pam!agent", TokenSecret: "s",
		},
	}
}

func TestValidateRejectsAnIncompleteProxmoxConfig(t *testing.T) {
	cases := map[string]func(*Config){
		"no control plane": func(c *Config) { c.ControlPlaneURL = "" },
		"http remote CP":   func(c *Config) { c.ControlPlaneURL = "http://app.bunkhosting.nl" },
		"no host":          func(c *Config) { c.Proxmox.Host = "" },
		"no node":          func(c *Config) { c.Proxmox.Node = "" },
		"no token id":      func(c *Config) { c.Proxmox.TokenID = "" },
		"no token secret":  func(c *Config) { c.Proxmox.TokenSecret = "" },
		"zero heartbeat":   func(c *Config) { c.HeartbeatInterval = 0 },
		// A negative interval would make the ticker panic at startup.
		"negative heartbeat": func(c *Config) { c.HeartbeatInterval = -time.Second },
		"unknown hypervisor": func(c *Config) { c.Hypervisor = "hyperv" },
		"empty hypervisor":   func(c *Config) { c.Hypervisor = "" },
	}
	for name, mutate := range cases {
		cfg := base()
		mutate(&cfg)
		if err := cfg.validate(); err == nil {
			t.Errorf("validate() accepted a config with %s", name)
		}
	}
}

func TestValidateAcceptsACompleteProxmoxConfig(t *testing.T) {
	if err := base().validate(); err != nil {
		t.Fatalf("validate() = %v", err)
	}
}

func TestValidateRejectsAnIncompleteEsxiConfig(t *testing.T) {
	esxi := func() Config {
		c := base()
		c.Hypervisor = "esxi"
		c.Esxi = EsxiConfig{URL: "https://esx", User: "root", Password: "pw", Template: "tpl"}
		return c
	}
	if err := esxi().validate(); err != nil {
		t.Fatalf("a complete esxi config was rejected: %v", err)
	}

	for name, mutate := range map[string]func(*Config){
		"no url":      func(c *Config) { c.Esxi.URL = "" },
		"no user":     func(c *Config) { c.Esxi.User = "" },
		"no password": func(c *Config) { c.Esxi.Password = "" },
		"no template": func(c *Config) { c.Esxi.Template = "" },
	} {
		cfg := esxi()
		mutate(&cfg)
		if err := cfg.validate(); err == nil {
			t.Errorf("validate() accepted an esxi config with %s", name)
		}
	}
}
