// Package transport defines the bunk-agent's client contract with the
// federated control plane.
//
// The agent always DIALS OUT (so it works behind NAT): it enrolls once with a
// one-time token to obtain a durable node identity and credentials, then
// periodically POSTs capacity heartbeats and long-polls for commands
// (provision / delete). Console proxying is intentionally out of scope here.
package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// CommandKind enumerates the command verbs the control plane may dispatch.
type CommandKind string

const (
	// CmdProvision asks the agent to create a VM. Payload is a JSON-encoded
	// provider.VMSpec-shaped object (decoded by the caller).
	CmdProvision CommandKind = "provision"
	// CmdDelete asks the agent to destroy a VM. Payload carries the target id.
	CmdDelete CommandKind = "delete"
	// CmdStart powers on a stopped VM. Payload carries the target id.
	CmdStart CommandKind = "start"
	// CmdStop powers off a running VM. Payload carries the target id.
	CmdStop CommandKind = "stop"
	// CmdPause suspends (to RAM) a running VM. Payload carries the target id.
	CmdPause CommandKind = "pause"
	// CmdResume un-suspends a paused VM. Payload carries the target id.
	CmdResume CommandKind = "resume"
)

// EnrollRequest is sent once to exchange a one-time token for node credentials.
type EnrollRequest struct {
	// Token is the one-time enrollment token issued by the control plane.
	Token string `json:"token"`
	// Hypervisor identifies the local backend, e.g. "proxmox".
	Hypervisor string `json:"hypervisor"`
	// AgentVersion is the build/version string of this agent.
	AgentVersion string `json:"agent_version"`
	// VpsGateway/VpsCidrPrefix/VpsRangeStart/VpsRangeEnd describe this worker's
	// VPS IP range so the control plane can allocate non-conflicting addresses.
	VpsGateway    string `json:"vps_gateway,omitempty"`
	VpsCidrPrefix int    `json:"vps_cidr_prefix,omitempty"`
	VpsRangeStart string `json:"vps_range_start,omitempty"`
	VpsRangeEnd   string `json:"vps_range_end,omitempty"`
	WgPublicKey   string `json:"wg_public_key,omitempty"`
}

// VpsNetwork is the IP-range part of a worker's VPS network, sent at enrollment.
type VpsNetwork struct {
	Gateway    string
	CidrPrefix int
	RangeStart string
	RangeEnd   string
}

// EnrollResponse carries the durable identity and credentials assigned to the
// node after a successful enrollment.
type EnrollResponse struct {
	// NodeID is the stable identifier assigned to this worker node.
	NodeID string `json:"node_id"`
	// AgentToken is the long-lived bearer token used to authenticate
	// subsequent heartbeat and command requests.
	AgentToken string `json:"agent_token"`
	// Overlay carries the WireGuard hub parameters when the overlay is enabled.
	Overlay *Overlay `json:"overlay,omitempty"`
}

// Overlay holds the WireGuard hub parameters returned at enrollment.
type Overlay struct {
	HubPublicKey string `json:"hub_public_key"`
	Endpoint     string `json:"endpoint"`
	HubIP        string `json:"hub_ip"`
	OverlayIP    string `json:"overlay_ip"`
	OverlayCIDR  string `json:"overlay_cidr"`
}

// Heartbeat is the periodic capacity report posted to the control plane.
type Heartbeat struct {
	// NodeID identifies the reporting node.
	NodeID string `json:"node_id"`
	// At is the timestamp the heartbeat was generated.
	At time.Time `json:"at"`
	// TotalVCPU/AvailVCPU/... mirror provider.Capacity. They are flat ints so
	// the transport package stays free of a provider import cycle; the caller
	// translates a provider.Capacity into this shape.
	TotalVCPU   int `json:"total_vcpu"`
	AvailVCPU   int `json:"avail_vcpu"`
	TotalRAMMB  int `json:"total_ram_mb"`
	AvailRAMMB  int `json:"avail_ram_mb"`
	TotalDiskGB int `json:"total_disk_gb"`
	AvailDiskGB int `json:"avail_disk_gb"`
}

// Command is a single instruction dispatched by the control plane.
type Command struct {
	// ID uniquely identifies the command for acknowledgement/idempotency.
	ID string `json:"id"`
	// Kind is the verb (provision, delete, ...).
	Kind CommandKind `json:"kind"`
	// Payload is the verb-specific body, decoded by the agent.
	Payload json.RawMessage `json:"payload"`
}

// CommandResult is the agent's report of how a dispatched command resolved. It
// is POSTed back to the control plane keyed by the originating command ID.
type CommandResult struct {
	// Status is the terminal outcome, typically "done" or "failed".
	Status string `json:"status"`
	// VMID is the provider-native guest identifier, when one was produced.
	VMID string `json:"vm_id"`
	// IP is the primary IPv4 address of the guest, when known.
	IP string `json:"ip"`
	// Error carries a human-readable failure reason when Status is "failed".
	Error string `json:"error"`
}

// Client is the HTTP control-plane client. It is safe for concurrent use.
type Client struct {
	baseURL string
	http    *http.Client

	// token is the bearer credential set after Enroll (or supplied directly).
	token  string
	nodeID string
}

// New returns a Client targeting the given control-plane base URL.
func New(baseURL string, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    httpClient,
	}
}

// NodeID returns the enrolled node identity (empty until Enroll succeeds or
// SetCredentials is called).
func (c *Client) NodeID() string { return c.nodeID }

// SetCredentials installs a previously-obtained identity and token, e.g. when
// loaded from disk so the agent need not re-enroll on every restart.
func (c *Client) SetCredentials(nodeID, token string) {
	c.nodeID = nodeID
	c.token = token
}

// post is a small helper that marshals body, performs an authenticated POST and
// decodes the JSON response into out (which may be nil).
func (c *Client) post(ctx context.Context, path string, body, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("transport: marshal %s: %w", path, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("transport: build %s: %w", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("transport: %s: %w", path, err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("transport: %s: status %d: %s", path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("transport: decode %s: %w", path, err)
	}
	return nil
}

// Enroll exchanges a one-time token for node credentials and stores them on the
// Client for subsequent calls.
// Version is the agent build string sent at enrollment. Override at build time
// with -ldflags "-X github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport.Version=<v>".
var Version = "dev"

func (c *Client) Enroll(ctx context.Context, token, hypervisor string, net VpsNetwork, wgPublicKey string) (EnrollResponse, error) {
	if token == "" {
		return EnrollResponse{}, errors.New("transport: empty enrollment token")
	}
	if hypervisor == "" {
		hypervisor = "proxmox"
	}
	var out EnrollResponse
	req := EnrollRequest{
		Token:         token,
		Hypervisor:    hypervisor,
		AgentVersion:  Version,
		VpsGateway:    net.Gateway,
		VpsCidrPrefix: net.CidrPrefix,
		VpsRangeStart: net.RangeStart,
		VpsRangeEnd:   net.RangeEnd,
		WgPublicKey:   wgPublicKey,
	}
	if err := c.post(ctx, "/v1/enroll", req, &out); err != nil {
		return EnrollResponse{}, err
	}
	if out.NodeID == "" || out.AgentToken == "" {
		return EnrollResponse{}, errors.New("transport: enrollment response missing node_id/agent_token")
	}
	c.SetCredentials(out.NodeID, out.AgentToken)
	return out, nil
}

// SendHeartbeat posts a single capacity heartbeat.
func (c *Client) SendHeartbeat(ctx context.Context, hb Heartbeat) error {
	if c.token == "" {
		return errors.New("transport: not enrolled (no agent token)")
	}
	if hb.NodeID == "" {
		hb.NodeID = c.nodeID
	}
	return c.post(ctx, "/v1/heartbeat", hb, nil)
}

// ReportResult posts the terminal outcome of a dispatched command back to the
// control plane, keyed by the originating command ID. It reuses the
// Bearer-authenticated post helper.
func (c *Client) ReportResult(ctx context.Context, commandID string, res CommandResult) error {
	if c.token == "" {
		return errors.New("transport: not enrolled (no agent token)")
	}
	if commandID == "" {
		return errors.New("transport: ReportResult requires a command ID")
	}
	path := "/v1/commands/" + url.PathEscape(commandID) + "/result"
	return c.post(ctx, path, res, nil)
}

// Commands long-polls the control plane and delivers dispatched commands on the
// returned channel. The channel is closed when ctx is cancelled or a fatal
// error occurs. Transient poll errors are retried with a backoff; this is the
// documented persistent-reconnection method for the command stream.
//
// Each long-poll request blocks server-side until a command is available or the
// poll window elapses (returning an empty list), keeping the agent reachable
// from behind NAT without inbound connectivity.
func (c *Client) Commands(ctx context.Context) (<-chan Command, error) {
	if c.token == "" {
		return nil, errors.New("transport: not enrolled (no agent token)")
	}
	out := make(chan Command)

	go func() {
		defer close(out)
		backoff := time.Second
		const maxBackoff = 30 * time.Second
		const pollFloor = 2 * time.Second

		for {
			if ctx.Err() != nil {
				return
			}
			cmds, err := c.pollCommands(ctx)
			if err != nil {
				// On cancellation, exit quietly.
				if ctx.Err() != nil {
					return
				}
				// Transient error: back off and retry.
				select {
				case <-ctx.Done():
					return
				case <-time.After(backoff):
				}
				if backoff < maxBackoff {
					backoff *= 2
					if backoff > maxBackoff {
						backoff = maxBackoff
					}
				}
				continue
			}
			backoff = time.Second // reset after a successful poll
			for _, cmd := range cmds {
				select {
				case <-ctx.Done():
					return
				case out <- cmd:
				}
			}
			// R3: the control plane answers command polls immediately (no
			// server-side long-poll), so on an empty result floor-sleep before
			// re-polling — otherwise this is a tight CPU loop hammering the CP.
			if len(cmds) == 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(pollFloor):
				}
			}
		}
	}()

	return out, nil
}

// pollCommands performs a single long-poll request and returns any pending
// commands (possibly empty).
func (c *Client) pollCommands(ctx context.Context) ([]Command, error) {
	pollURL := c.baseURL + "/v1/commands?node_id=" + url.QueryEscape(c.nodeID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pollURL, nil)
	if err != nil {
		return nil, fmt.Errorf("transport: build commands poll: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("transport: commands poll: %w", err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("transport: commands poll: status %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}

	// The control plane returns a bare JSON array of commands:
	//   [{"id":"...","kind":"provision","payload":{...}}]
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, nil
	}
	var cmds []Command
	if err := json.Unmarshal(raw, &cmds); err != nil {
		return nil, fmt.Errorf("transport: decode commands: %w", err)
	}
	return cmds, nil
}
