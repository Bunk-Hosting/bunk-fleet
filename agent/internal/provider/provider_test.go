package provider

import (
	"encoding/json"
	"reflect"
	"testing"
)

// TestVMSpecSnakeCaseRoundTrip verifies that a snake_case provision payload
// (the on-the-wire control-plane contract) unmarshals into VMSpec, and that
// re-marshalling preserves the same field names. This guards the JSON tags
// against accidental drift.
func TestVMSpecSnakeCaseRoundTrip(t *testing.T) {
	const payload = `{
		"name": "web-01",
		"vcpu": 4,
		"ram_mb": 8192,
		"disk_gb": 40,
		"template_id": 9000,
		"cloud_init": {"user": "bunk", "password": "hash"},
		"ssh_keys": ["ssh-ed25519 AAAA key-a", "ssh-rsa BBBB key-b"],
		"ip_config": "ip=192.0.2.10/24,gw=192.0.2.1"
	}`

	var got VMSpec
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatalf("unmarshal VMSpec: %v", err)
	}

	want := VMSpec{
		Name:       "web-01",
		VCPU:       4,
		RAMMB:      8192,
		DiskGB:     40,
		TemplateID: 9000,
		CloudInit:  map[string]string{"user": "bunk", "password": "hash"},
		SSHKeys:    []string{"ssh-ed25519 AAAA key-a", "ssh-rsa BBBB key-b"},
		IPConfig:   "ip=192.0.2.10/24,gw=192.0.2.1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("decoded VMSpec mismatch:\n got  %+v\n want %+v", got, want)
	}

	// Re-marshal and confirm the snake_case keys survive the round trip.
	out, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal VMSpec: %v", err)
	}
	var asMap map[string]json.RawMessage
	if err := json.Unmarshal(out, &asMap); err != nil {
		t.Fatalf("unmarshal marshalled VMSpec: %v", err)
	}
	for _, key := range []string{"name", "vcpu", "ram_mb", "disk_gb", "template_id", "cloud_init", "ssh_keys", "ip_config"} {
		if _, ok := asMap[key]; !ok {
			t.Errorf("marshalled VMSpec missing key %q (got keys %v)", key, keysOf(asMap))
		}
	}
}

// TestVMStatusSnakeCaseRoundTrip verifies the VMStatus wire contract.
func TestVMStatusSnakeCaseRoundTrip(t *testing.T) {
	const payload = `{"id": "101", "state": "provisioning", "ip": "192.0.2.10"}`

	var got VMStatus
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatalf("unmarshal VMStatus: %v", err)
	}
	want := VMStatus{ID: "101", State: "provisioning", IP: "192.0.2.10"}
	if got != want {
		t.Fatalf("decoded VMStatus = %+v, want %+v", got, want)
	}

	out, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal VMStatus: %v", err)
	}
	var asMap map[string]json.RawMessage
	if err := json.Unmarshal(out, &asMap); err != nil {
		t.Fatalf("unmarshal marshalled VMStatus: %v", err)
	}
	for _, key := range []string{"id", "state", "ip"} {
		if _, ok := asMap[key]; !ok {
			t.Errorf("marshalled VMStatus missing key %q (got keys %v)", key, keysOf(asMap))
		}
	}
}

func keysOf(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
