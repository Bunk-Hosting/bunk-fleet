package transport

import "testing"

func TestConsoleRelayURL(t *testing.T) {
	cases := []struct {
		base string
		want string
	}{
		{"https://app.bunkhosting.nl", "wss://app.bunkhosting.nl/v1/console-relay?token=t0k"},
		{"https://app.bunkhosting.nl/", "wss://app.bunkhosting.nl/v1/console-relay?token=t0k"},
		{"http://localhost:4000", "ws://localhost:4000/v1/console-relay?token=t0k"},
	}
	for _, c := range cases {
		got, err := consoleRelayURL(c.base, "t0k")
		if err != nil || got != c.want {
			t.Errorf("consoleRelayURL(%q) = %q, %v; want %q", c.base, got, err, c.want)
		}
	}
}

func TestConsoleRelayURLEscapesTheToken(t *testing.T) {
	// The token is base64url, but nothing downstream should depend on that.
	got, err := consoleRelayURL("https://cp.example", "a+b/c=&x")
	if err != nil {
		t.Fatal(err)
	}
	want := "wss://cp.example/v1/console-relay?token=a%2Bb%2Fc%3D%26x"
	if got != want {
		t.Errorf("consoleRelayURL = %q, want %q", got, want)
	}
}

func TestConsoleRelayURLRejectsANonHTTPBase(t *testing.T) {
	for _, base := range []string{"ftp://cp.example", "cp.example", ""} {
		if _, err := consoleRelayURL(base, "t"); err == nil {
			t.Errorf("consoleRelayURL(%q) accepted a base URL with no http(s) scheme", base)
		}
	}
}
