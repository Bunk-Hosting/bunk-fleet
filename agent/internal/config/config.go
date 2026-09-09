// Package config loads bunk-agent configuration from command-line flags with
// environment-variable fallbacks. Flags take precedence over the environment;
// the environment takes precedence over built-in defaults.
package config

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
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

// OfferConfig caps how much of this machine is dedicated to the VPS pool, i.e.
// the capacity advertised to the control plane. A zero value for a dimension
// means "all of it"; a non-zero value reserves the remainder for whatever else
// the node runs.
type OfferConfig struct {
	VCPU   int
	RAMMB  int
	DiskGB int
}

// VpsNetworkConfig describes how this worker attaches and addresses customer
// VPSes. Bridge/VLAN are applied locally to each VM's NIC; the IP range is also
// reported to the control plane so it can hand out non-conflicting addresses.
type VpsNetworkConfig struct {
	Bridge     string
	VLAN       int
	Gateway    string
	CidrPrefix int
	RangeStart string
	RangeEnd   string
}

// EsxiConfig holds vSphere/ESXi connection + placement parameters.
type EsxiConfig struct {
	URL          string
	User         string
	Password     string
	Insecure     bool
	Datacenter   string
	Datastore    string
	ResourcePool string
	Folder       string
	Template     string
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
	// Esxi holds vSphere/ESXi settings (used when Hypervisor == "esxi").
	Esxi EsxiConfig
	// HeartbeatInterval controls how often capacity is reported.
	HeartbeatInterval time.Duration
	// StateDir is where the agent persists its enrollment so it survives restarts.
	StateDir string
	// Offer caps the capacity advertised to the control plane (0 per dimension = all).
	Offer OfferConfig
	// VpsNetwork configures the network VPSes are attached to and addressed on.
	VpsNetwork VpsNetworkConfig
}

// envOr returns the environment variable named key, or def if unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// A set-but-unparseable typed env var must NOT silently fall back to the default:
// e.g. BUNK_ESXI_INSECURE=ture → false would block the connection with a confusing
// TLS error, and BUNK_VPS_VLAN=1oo → untagged is a tenant-isolation hazard. The
// helpers below record such cases into an accumulator that Load() surfaces as a
// fatal config error, while an UNSET var still cleanly uses the default.

// envBool parses a boolean environment variable, falling back to def when unset.
func envBool(key string, def bool, errs *[]error) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("config: %s=%q is not a valid boolean", key, v))
		return def
	}
	return b
}

// envDuration parses a duration environment variable, falling back to def when unset.
func envDuration(key string, def time.Duration, errs *[]error) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("config: %s=%q is not a valid duration (e.g. 30s, 1m)", key, v))
		return def
	}
	return d
}

// envInt parses an integer environment variable, falling back to def when unset.
func envInt(key string, def int, errs *[]error) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("config: %s=%q is not a valid integer", key, v))
		return def
	}
	return n
}

// Load parses flags (with env fallbacks) and returns the resolved Config. It
// validates required fields and returns a descriptive error if any are missing
// or malformed.
func Load() (Config, error) {
	fs := flag.NewFlagSet("bunk-agent", flag.ContinueOnError)

	// Accumulates "set-but-unparseable env var" errors from the typed helpers
	// below; surfaced as a single fatal config error after flag parsing.
	var envErrs []error

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
		pveVerify = fs.Bool("proxmox-verify-ssl", envBool("BUNK_PROXMOX_VERIFY_SSL", true, &envErrs), "verify Proxmox TLS certificate")

		heartbeat = fs.Duration("heartbeat-interval", envDuration("BUNK_HEARTBEAT_INTERVAL", 30*time.Second, &envErrs), "capacity heartbeat interval")

		stateDir = fs.String("state-dir", envOr("BUNK_STATE_DIR", "/var/lib/bunk-agent"), "directory for persisted enrollment state")

		esxiURL      = fs.String("esxi-url", envOr("BUNK_ESXI_URL", ""), "vSphere/ESXi SDK URL (https://host/sdk)")
		esxiUser     = fs.String("esxi-user", envOr("BUNK_ESXI_USER", ""), "vSphere/ESXi username")
		esxiPass     = fs.String("esxi-password", envOr("BUNK_ESXI_PASSWORD", ""), "vSphere/ESXi password")
		esxiInsecure = fs.Bool("esxi-insecure", envBool("BUNK_ESXI_INSECURE", false, &envErrs), "skip vSphere TLS verification")
		esxiDC       = fs.String("esxi-datacenter", envOr("BUNK_ESXI_DATACENTER", ""), "vSphere datacenter (default when empty)")
		esxiDS       = fs.String("esxi-datastore", envOr("BUNK_ESXI_DATASTORE", ""), "vSphere datastore (default when empty)")
		esxiPool     = fs.String("esxi-resource-pool", envOr("BUNK_ESXI_RESOURCE_POOL", ""), "vSphere resource pool (default when empty)")
		esxiFolder   = fs.String("esxi-folder", envOr("BUNK_ESXI_FOLDER", ""), "vSphere VM folder (default when empty)")
		esxiTemplate = fs.String("esxi-template", envOr("BUNK_ESXI_TEMPLATE", ""), "template VM name to clone")

		offerVCPU = fs.Int("offer-vcpu", envInt("BUNK_OFFER_VCPU", 0, &envErrs), "max vCPUs to advertise (0 = all)")
		offerRAM  = fs.Int("offer-ram-mb", envInt("BUNK_OFFER_RAM_MB", 0, &envErrs), "max RAM (MB) to advertise (0 = all)")
		offerDisk = fs.Int("offer-disk-gb", envInt("BUNK_OFFER_DISK_GB", 0, &envErrs), "max disk (GB) to advertise (0 = all)")

		vpsBridge     = fs.String("vps-bridge", envOr("BUNK_VPS_BRIDGE", ""), "Proxmox bridge for VPS NICs (e.g. vmbr0); empty = inherit template")
		vpsVLAN       = fs.Int("vps-vlan", envInt("BUNK_VPS_VLAN", 0, &envErrs), "VLAN tag for VPS NICs (0 = untagged)")
		vpsGateway    = fs.String("vps-gateway", envOr("BUNK_VPS_GATEWAY", ""), "gateway address for VPS IPs")
		vpsCidrPrefix = fs.Int("vps-cidr-prefix", envInt("BUNK_VPS_CIDR_PREFIX", 0, &envErrs), "CIDR prefix length for VPS IPs (e.g. 24)")
		vpsRangeStart = fs.String("vps-range-start", envOr("BUNK_VPS_RANGE_START", ""), "first assignable VPS IP")
		vpsRangeEnd   = fs.String("vps-range-end", envOr("BUNK_VPS_RANGE_END", ""), "last assignable VPS IP")
	)

	if err := fs.Parse(os.Args[1:]); err != nil {
		return Config{}, err
	}
	if len(envErrs) > 0 {
		return Config{}, errors.Join(envErrs...)
	}

	cfg := Config{
		ControlPlaneURL:   *controlPlaneURL,
		EnrollToken:       *enrollToken,
		Hypervisor:        *hypervisor,
		HeartbeatInterval: *heartbeat,
		StateDir:          *stateDir,
		Offer:             OfferConfig{VCPU: *offerVCPU, RAMMB: *offerRAM, DiskGB: *offerDisk},
		VpsNetwork: VpsNetworkConfig{
			Bridge:     *vpsBridge,
			VLAN:       *vpsVLAN,
			Gateway:    *vpsGateway,
			CidrPrefix: *vpsCidrPrefix,
			RangeStart: *vpsRangeStart,
			RangeEnd:   *vpsRangeEnd,
		},
		Proxmox: ProxmoxConfig{
			Host:        *pveHost,
			Node:        *pveNode,
			TokenID:     *pveTokID,
			TokenSecret: *pveSecret,
			VerifySSL:   *pveVerify,
		},
		Esxi: EsxiConfig{
			URL:          *esxiURL,
			User:         *esxiUser,
			Password:     *esxiPass,
			Insecure:     *esxiInsecure,
			Datacenter:   *esxiDC,
			Datastore:    *esxiDS,
			ResourcePool: *esxiPool,
			Folder:       *esxiFolder,
			Template:     *esxiTemplate,
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
	if err := validateControlPlaneURL(c.ControlPlaneURL); err != nil {
		return err
	}
	switch c.Hypervisor {
	case "proxmox":
		if c.Proxmox.Host == "" || c.Proxmox.Node == "" {
			return errors.New("config: proxmox-host and proxmox-node are required")
		}
		if c.Proxmox.TokenID == "" || c.Proxmox.TokenSecret == "" {
			return errors.New("config: proxmox-token-id and proxmox-token-secret are required")
		}
	case "esxi":
		if c.Esxi.URL == "" || c.Esxi.User == "" || c.Esxi.Password == "" {
			return errors.New("config: esxi-url, esxi-user and esxi-password are required")
		}
		if c.Esxi.Template == "" {
			return errors.New("config: esxi-template is required")
		}
	default:
		return fmt.Errorf("config: unsupported hypervisor %q (proxmox or esxi)", c.Hypervisor)
	}
	if c.HeartbeatInterval <= 0 {
		return errors.New("config: heartbeat-interval must be positive")
	}
	return nil
}

// validateControlPlaneURL enforces https for any non-internal control-plane host
// (H3): plain http would let a MITM on the node's LAN steal the
// agent token and inject/replay commands. http is allowed ONLY for loopback,
// RFC1918 private IPs, or single-label hostnames (e.g. a docker service name).
func validateControlPlaneURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("config: invalid control-plane-url: %w", err)
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		if isInternalHost(u.Hostname()) {
			return nil
		}
		return fmt.Errorf("config: control-plane-url must use https for remote host %q (plain http is only allowed for loopback/private)", u.Hostname())
	default:
		return fmt.Errorf("config: control-plane-url must be http or https, got %q", u.Scheme)
	}
}

func isInternalHost(host string) bool {
	switch {
	case host == "":
		return false
	case host == "localhost":
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
	}
	// single-label hostname (no dot), e.g. a docker service name like bf-prod-cp
	return !strings.Contains(host, ".")
}
