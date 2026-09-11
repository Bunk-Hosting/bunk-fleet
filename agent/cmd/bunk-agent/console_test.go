package main

import (
	"net"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
)

func mustSubnet(t *testing.T, gateway string, prefix int) *net.IPNet {
	t.Helper()
	subnet, err := vpsNetwork{Gateway: gateway, CidrPrefix: prefix}.subnet()
	if err != nil {
		t.Fatal(err)
	}
	return subnet
}

func TestAllowedConsoleTargetAcceptsAVpsOnOurOwnSubnet(t *testing.T) {
	subnet := mustSubnet(t, "10.10.4.1", 22)
	for _, host := range []string{"10.10.4.20", "10.10.5.1", "10.10.7.254"} {
		if err := allowedConsoleTarget(host, subnet); err != nil {
			t.Errorf("allowedConsoleTarget(%s) = %v, want nil", host, err)
		}
	}
}

func TestAllowedConsoleTargetRefusesOutsideOurSubnet(t *testing.T) {
	// The control plane names the target, so a bug or a compromised control
	// plane must not be able to walk the operator's LAN through our agent.
	subnet := mustSubnet(t, "10.10.4.1", 22)
	for _, host := range []string{"10.10.0.21", "192.168.1.70", "10.10.8.1"} {
		if err := allowedConsoleTarget(host, subnet); err == nil {
			t.Errorf("allowedConsoleTarget(%s) accepted an address outside %s", host, subnet)
		}
	}
}

func TestAllowedConsoleTargetRefusesDangerousAddressesEvenWithoutASubnet(t *testing.T) {
	cases := map[string]string{
		"169.254.169.254": "cloud metadata endpoint — credentials on a rented node",
		"127.0.0.1":       "loopback — the agent's own services",
		"::1":             "loopback",
		"8.8.8.8":         "public internet — would make the node an open proxy",
		"0.0.0.0":         "unspecified",
		"224.0.0.1":       "multicast",
		"fe80::1":         "link-local",
		"example.com":     "hostname — DNS would decide the target after the check",
		"":                "empty",
	}
	for host, why := range cases {
		if err := allowedConsoleTarget(host, nil); err == nil {
			t.Errorf("allowedConsoleTarget(%q) accepted it (%s)", host, why)
		}
	}
}

func TestAllowedConsoleTargetAcceptsPrivateAddressesWithoutASubnet(t *testing.T) {
	// A node that enrolled before the control plane sent its network back still
	// has to be able to serve a console.
	for _, host := range []string{"10.10.0.21", "192.168.1.50", "172.16.3.4"} {
		if err := allowedConsoleTarget(host, nil); err != nil {
			t.Errorf("allowedConsoleTarget(%s, nil) = %v, want nil", host, err)
		}
	}
}

func TestAssignedSubnetPrefersEnrolmentOverEnvironment(t *testing.T) {
	st := persistedState{VpsGateway: "10.10.4.1", VpsCidrPrefix: 22}
	cfg := config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}

	got := assignedSubnet(st, cfg)
	if got == nil || got.String() != "10.10.4.0/22" {
		t.Fatalf("assignedSubnet = %v, want 10.10.4.0/22", got)
	}
}

func TestAssignedSubnetFallsBackToTheDeclaredNetwork(t *testing.T) {
	cfg := config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}

	got := assignedSubnet(persistedState{}, cfg)
	if got == nil || got.String() != "192.168.50.0/24" {
		t.Fatalf("assignedSubnet = %v, want 192.168.50.0/24", got)
	}
}

func TestAssignedSubnetIsNilWhenNothingIsKnown(t *testing.T) {
	if got := assignedSubnet(persistedState{}, config.VpsNetworkConfig{}); got != nil {
		t.Fatalf("assignedSubnet = %v, want nil", got)
	}
	// A malformed value must not be treated as a subnet either.
	bad := persistedState{VpsGateway: "nonsense", VpsCidrPrefix: 22}
	if got := assignedSubnet(bad, config.VpsNetworkConfig{}); got != nil {
		t.Fatalf("assignedSubnet(malformed) = %v, want nil", got)
	}
}
