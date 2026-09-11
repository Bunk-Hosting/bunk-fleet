package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// vpsNetwork is the addressing this node serves its customer VPSes on, as the
// control plane recorded it. The agent may have proposed it at enrollment or the
// control plane may have carved it out of the fleet supernet — either way what
// comes back is authoritative, because it is what the control plane will put in
// each VPS's cloud-init.
type vpsNetwork struct {
	Gateway    string
	CidrPrefix int
}

// ifaceName matches a Linux interface name: no shell metacharacters, no leading
// dash that a command could read as a flag, and within IFNAMSIZ.
var ifaceName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$`)

// subnet derives the network the VPSes live on from the gateway address and
// prefix — "10.10.4.1" /22 is the gateway of 10.10.4.0/22.
func (n vpsNetwork) subnet() (*net.IPNet, error) {
	if n.CidrPrefix < 1 || n.CidrPrefix > 32 {
		return nil, fmt.Errorf("netsetup: prefix /%d out of range", n.CidrPrefix)
	}
	ip := net.ParseIP(n.Gateway)
	if ip == nil || ip.To4() == nil {
		return nil, fmt.Errorf("netsetup: gateway %q is not an IPv4 address", n.Gateway)
	}
	_, ipnet, err := net.ParseCIDR(fmt.Sprintf("%s/%d", ip.To4().String(), n.CidrPrefix))
	if err != nil {
		return nil, fmt.Errorf("netsetup: %w", err)
	}
	return ipnet, nil
}

// uplinkFromRoutes picks the interface the default route leaves by, which is the
// interface customer traffic has to be NATed onto. Reads `ip route show default`
// output rather than shelling out to anything clever.
func uplinkFromRoutes(routeOutput string) (string, error) {
	for _, line := range strings.Split(routeOutput, "\n") {
		fields := strings.Fields(line)
		for i := 0; i < len(fields)-1; i++ {
			if fields[i] == "dev" && ifaceName.MatchString(fields[i+1]) {
				return fields[i+1], nil
			}
		}
	}
	return "", fmt.Errorf("netsetup: no default route to NAT customer traffic onto")
}

// natRules is every firewall rule this node needs for its VPS network, as
// iptables argument vectors. Outbound is allowed and masqueraded; inbound is only
// allowed as the return half of a connection a VPS opened, which is exactly the
// shared-IPv4 tier we sell. A VPS that has bought its own address gets its rules
// elsewhere; nothing here forwards unsolicited inbound traffic.
func natRules(bridge, uplink string, subnet *net.IPNet) [][]string {
	cidr := subnet.String()
	return [][]string{
		{"-t", "nat", "-A", "POSTROUTING", "-s", cidr, "-o", uplink, "-j", "MASQUERADE"},
		{"-A", "FORWARD", "-i", bridge, "-s", cidr, "-o", uplink, "-j", "ACCEPT"},
		{
			"-A", "FORWARD", "-i", uplink, "-o", bridge, "-d", cidr,
			"-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT",
		},
	}
}

// checkArgs turns an append rule into the -C form that asks "is this already
// there?", so applying the same rule twice is a no-op instead of a duplicate.
func checkArgs(rule []string) []string {
	out := make([]string, len(rule))
	copy(out, rule)
	for i, arg := range out {
		if arg == "-A" {
			out[i] = "-C"
			break
		}
	}
	return out
}

// applyVpsNetwork brings up the node's customer network: the bridge holds the
// gateway address, forwarding is on, and customer traffic leaves NATed on this
// node's own uplink.
//
// It runs on every agent start, not once at enrollment, so a reboot or a
// hand-edited firewall heals itself. Every step is idempotent and scoped to this
// node's own bridge and subnet — no chain is ever flushed, and no rule that does
// not mention this subnet is touched.
//
// Failures are logged, not fatal: an operator who manages their own networking
// sets BUNK_MANAGE_NETWORK=0 and nothing here runs at all.
func applyVpsNetwork(logger *slog.Logger, bridge string, n vpsNetwork, manage bool) {
	if !manage {
		logger.Info("vps network: not managed (BUNK_MANAGE_NETWORK=0); configure the bridge yourself",
			"bridge", bridge, "gateway", n.Gateway, "prefix", n.CidrPrefix)
		return
	}
	if n.Gateway == "" {
		logger.Warn("vps network: control plane assigned no gateway; customer VPSes will have no network")
		return
	}
	if bridge == "" {
		logger.Warn("vps network: no bridge configured; set BUNK_VPS_BRIDGE (e.g. vmbr2) " +
			"so the agent knows which bridge to put the customer gateway on")
		return
	}
	if !ifaceName.MatchString(bridge) {
		logger.Warn("vps network: refusing to configure an implausible bridge name", "bridge", bridge)
		return
	}
	subnet, err := n.subnet()
	if err != nil {
		logger.Warn("vps network: rejecting malformed parameters from control plane", "err", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := ensureBridge(ctx, bridge); err != nil {
		logger.Warn("vps network: cannot bring up bridge", "bridge", bridge, "err", err)
		return
	}

	addr := fmt.Sprintf("%s/%d", n.Gateway, n.CidrPrefix)
	if out, err := runCmd(ctx, "ip", "addr", "replace", addr, "dev", bridge); err != nil {
		logger.Warn("vps network: cannot set gateway address", "addr", addr, "err", err, "detail", out)
		return
	}

	if out, err := runCmd(ctx, "sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
		logger.Warn("vps network: cannot enable IPv4 forwarding", "err", err, "detail", out)
		return
	}

	routes, err := runCmd(ctx, "ip", "-4", "route", "show", "default")
	if err != nil {
		logger.Warn("vps network: cannot read routing table", "err", err, "detail", routes)
		return
	}
	uplink, err := uplinkFromRoutes(routes)
	if err != nil {
		logger.Warn("vps network: no uplink for customer traffic", "err", err)
		return
	}

	for _, rule := range natRules(bridge, uplink, subnet) {
		if _, err := runCmd(ctx, "iptables", checkArgs(rule)...); err == nil {
			continue // already present
		}
		if out, err := runCmd(ctx, "iptables", rule...); err != nil {
			logger.Warn("vps network: cannot install firewall rule",
				"rule", strings.Join(rule, " "), "err", err, "detail", out)
			return
		}
	}

	logger.Info("vps network ready",
		"bridge", bridge, "gateway", addr, "subnet", subnet.String(), "uplink", uplink)
}

// ensureBridge creates the bridge when it is missing and brings it up. A bridge
// with no ports carries no traffic until a VM's tap is attached to it, so
// creating one is inert — but it must exist before an address can go on it.
func ensureBridge(ctx context.Context, bridge string) error {
	if _, err := runCmd(ctx, "ip", "link", "show", bridge); err != nil {
		if out, err := runCmd(ctx, "ip", "link", "add", "name", bridge, "type", "bridge"); err != nil {
			return fmt.Errorf("creating bridge: %v (%s)", err, out)
		}
	}
	if out, err := runCmd(ctx, "ip", "link", "set", bridge, "up"); err != nil {
		return fmt.Errorf("bringing bridge up: %v (%s)", err, out)
	}
	return nil
}

// runCmd executes a command and returns its combined output, which is what the
// warnings above quote when a step fails — iptables and ip both explain
// themselves on stderr.
func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// networkFromState reads the assigned network back out of persisted state, so a
// restart reconfigures the same bridge without going near the control plane.
func networkFromState(st persistedState) vpsNetwork {
	return vpsNetwork{Gateway: st.VpsGateway, CidrPrefix: st.VpsCidrPrefix}
}
