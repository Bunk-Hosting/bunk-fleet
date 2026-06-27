package proxmox

import "testing"

func TestEncodeProxmoxSSHKeys(t *testing.T) {
	got := encodeProxmoxSSHKeys([]string{"ssh-rsa AAAAB3Nz+a/b user@host\n"})

	if got == "" {
		t.Fatal("expected non-empty encoding")
	}
	for _, bad := range []string{"+", "%0A"} {
		if containsSubstr(got, bad) {
			t.Fatalf("encoding must not contain %q: %s", bad, got)
		}
	}
	if !containsSubstr(got, "%20") {
		t.Fatalf("spaces must be encoded as %%20: %s", got)
	}
}

func containsSubstr(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
