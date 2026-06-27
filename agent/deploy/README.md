# Worker agent deployment (systemd)

1. Build the static binary and install it:
   `docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine sh -c 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /src/bunk-agent ./cmd/bunk-agent'`
   `install -m0755 bunk-agent /usr/local/bin/bunk-agent`
2. `mkdir -p /etc/bunk-agent && cp deploy/agent.env.example /etc/bunk-agent/agent.env && chmod 600 /etc/bunk-agent/agent.env`
   then fill in BUNK_ENROLL_TOKEN (from `POST /api/v1/operator/enroll-tokens`) + the Proxmox token.
3. `cp deploy/bunk-agent.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now bunk-agent`
4. `journalctl -u bunk-agent -f` — expect "enrolled with control plane" then "heartbeat sent".

Enrollment state persists in /var/lib/bunk-agent/state.json, so restarts keep the
same node identity (no re-enroll / no fresh token needed).
