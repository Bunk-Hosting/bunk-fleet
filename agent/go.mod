module github.com/Bunk-Hosting/bunk-fleet/agent

go 1.25.0

// Pinned deliberately, and kept current. The agent runs on hardware we do not
// own and speaks TLS to the control plane, so its standard library is part of
// the attack surface: on 1.23.12 govulncheck reported 25 reachable stdlib
// vulnerabilities, several in crypto/x509 and net/http. Bumping the toolchain
// is the whole fix — there is no dependency to patch.

require (
	github.com/coder/websocket v1.8.15
	github.com/vmware/govmomi v0.43.0
)

require github.com/google/uuid v1.6.0 // indirect
