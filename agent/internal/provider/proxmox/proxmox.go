// Package proxmox implements provider.Provider against the Proxmox VE REST
// API (/api2/json) using API-token authentication.
//
// Authentication uses the header:
//
//	Authorization: PVEAPIToken=USER@REALM!TOKENID=SECRET
//
// which requires no login ticket / CSRF dance and is well suited to an
// unattended agent.
package proxmox

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// Config holds the connection parameters for a Proxmox VE node.
type Config struct {
	// Host is the base URL of the PVE API, e.g. "https://10.0.0.5:8006".
	Host string
	// Node is the cluster node name targeted by this agent, e.g. "pve".
	Node string
	// TokenID is the full token identifier "USER@REALM!TOKENID".
	TokenID string
	// TokenSecret is the secret UUID value of the API token.
	TokenSecret string
	// VerifySSL toggles TLS certificate verification. Many homelab PVE nodes
	// use self-signed certs, so this may be false in practice.
	VerifySSL bool
	// Bridge, when set, is forced as the VPS NIC bridge (else the template's NIC
	// is inherited). VLAN > 0 adds an 802.1q tag for a dedicated VPS network.
	Bridge string
	VLAN   int
}

// Client is a Proxmox VE provider implementation.
type Client struct {
	cfg  Config
	base string
	http *http.Client
}

// compile-time assertion that Client satisfies provider.Provider.
var _ provider.Provider = (*Client)(nil)

// New constructs a Client from cfg. It returns an error if required fields are
// missing.
// safeBridge reports whether s is a non-empty, alphanumeric Proxmox bridge name,
// preventing injection of extra options into the net0 parameter string.
func safeBridge(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}

func New(cfg Config) (*Client, error) {
	if cfg.Host == "" {
		return nil, errors.New("proxmox: Host is required")
	}
	if cfg.Node == "" {
		return nil, errors.New("proxmox: Node is required")
	}
	if cfg.TokenID == "" || cfg.TokenSecret == "" {
		return nil, errors.New("proxmox: TokenID and TokenSecret are required")
	}
	return &Client{
		cfg:  cfg,
		base: strings.TrimRight(cfg.Host, "/") + "/api2/json",
		http: httpClient(cfg.VerifySSL),
	}, nil
}

// httpClient builds an *http.Client whose transport optionally skips TLS
// verification (for self-signed PVE certificates).
func httpClient(verifySSL bool) *http.Client {
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: !verifySSL, //nolint:gosec // our own nodes, self-signed Proxmox certs
		},
	}
	return &http.Client{
		Timeout:   30 * time.Second,
		Transport: tr,
	}
}

// authHeader returns the value for the Authorization header.
func authHeader(tokenID, secret string) string {
	return "PVEAPIToken=" + tokenID + "=" + secret
}

// Name implements provider.Provider.
func (c *Client) Name() string { return "proxmox" }

// doJSON performs an authenticated request against the PVE API and decodes the
// JSON response into out (which may be nil). For POST/PUT, body is encoded as
// application/x-www-form-urlencoded from form.
func (c *Client) doJSON(ctx context.Context, method, path string, form url.Values, out any) error {
	var bodyReader io.Reader
	if form != nil {
		bodyReader = strings.NewReader(form.Encode())
	}

	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bodyReader)
	if err != nil {
		return fmt.Errorf("proxmox: build request: %w", err)
	}
	req.Header.Set("Authorization", authHeader(c.cfg.TokenID, c.cfg.TokenSecret))
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("proxmox: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return fmt.Errorf("proxmox: read body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("proxmox: %s %s: status %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("proxmox: decode %s %s: %w", method, path, err)
	}
	return nil
}

// --- Capacity -------------------------------------------------------------

// nodeStatus mirrors the subset of GET /nodes/{node}/status we consume.
type nodeStatus struct {
	Data struct {
		CPUInfo struct {
			CPUs int `json:"cpus"`
		} `json:"cpuinfo"`
		Memory struct {
			Total int64 `json:"total"`
			Used  int64 `json:"used"`
			Free  int64 `json:"free"`
		} `json:"memory"`
		RootFS struct {
			Total int64 `json:"total"`
			Used  int64 `json:"used"`
			Avail int64 `json:"avail"`
			Free  int64 `json:"free"`
		} `json:"rootfs"`
	} `json:"data"`
}

// guestEntry mirrors entries from GET /nodes/{node}/qemu (the VM list).
type guestEntry struct {
	VMID   int     `json:"vmid"`
	Name   string  `json:"name"`
	Status string  `json:"status"`
	CPUs   float64 `json:"cpus"`
	MaxMem int64   `json:"maxmem"`
}

type guestList struct {
	Data []guestEntry `json:"data"`
}

// parseCapacity computes a Capacity snapshot from a node status payload and the
// list of guests. Available vCPU is derived by subtracting the sum of vCPUs
// assigned to running guests from the node's physical core count (clamped at
// zero). Memory/disk availability come straight from the node status.
//
// It is split out from Capacity so it can be unit-tested without a live PVE.
func parseCapacity(ns nodeStatus, guests []guestEntry) provider.Capacity {
	const mib = 1 << 20
	const gib = 1 << 30

	totalVCPU := ns.Data.CPUInfo.CPUs

	usedVCPU := 0
	for _, g := range guests {
		if g.Status == "running" {
			usedVCPU += int(g.CPUs)
		}
	}
	availVCPU := totalVCPU - usedVCPU
	if availVCPU < 0 {
		availVCPU = 0
	}

	out := provider.Capacity{
		TotalVCPU:   totalVCPU,
		AvailVCPU:   availVCPU,
		TotalRAMMB:  int(ns.Data.Memory.Total / mib),
		AvailRAMMB:  int(ns.Data.Memory.Free / mib),
		TotalDiskGB: int(ns.Data.RootFS.Total / gib),
		AvailDiskGB: int(ns.Data.RootFS.Avail / gib),
	}
	// RootFS may report "free" rather than "avail" on some versions.
	if out.AvailDiskGB == 0 && ns.Data.RootFS.Free > 0 {
		out.AvailDiskGB = int(ns.Data.RootFS.Free / gib)
	}
	return out
}

// Capacity implements provider.Provider. It queries node status and the guest
// list and combines them on a best-effort basis.
func (c *Client) Capacity(ctx context.Context) (provider.Capacity, error) {
	var ns nodeStatus
	if err := c.doJSON(ctx, http.MethodGet, "/nodes/"+url.PathEscape(c.cfg.Node)+"/status", nil, &ns); err != nil {
		return provider.Capacity{}, err
	}

	var gl guestList
	// A failure to list guests is non-fatal: we still report node totals.
	if err := c.doJSON(ctx, http.MethodGet, "/nodes/"+url.PathEscape(c.cfg.Node)+"/qemu", nil, &gl); err != nil {
		return parseCapacity(ns, nil), nil
	}
	return parseCapacity(ns, gl.Data), nil
}

// --- Lifecycle ------------------------------------------------------------

// taskResponse is the standard PVE "UPID" wrapper returned by async ops.
type taskResponse struct {
	Data string `json:"data"`
}

// taskStatus mirrors GET /nodes/{node}/tasks/{upid}/status. While a task runs,
// Status is "running"; once finished it is "stopped" and ExitStatus carries the
// outcome ("OK" on success, otherwise an error string).
type taskStatus struct {
	Data struct {
		Status     string `json:"status"`
		ExitStatus string `json:"exitstatus"`
	} `json:"data"`
}

// taskPollInterval is how often waitTask re-checks an in-flight UPID.
const taskPollInterval = 2 * time.Second

// taskState is the distilled outcome of a single task-status poll, split out so
// the decision logic can be unit-tested without a live PVE.
type taskState int

const (
	taskRunning taskState = iota // still in progress; keep polling
	taskOK                       // finished successfully (stopped + exitstatus OK)
	taskFailed                   // finished with a non-OK exit status
)

// evalTaskStatus interprets a decoded task-status body. When the task has
// failed it also returns the raw exit-status string for diagnostics.
func evalTaskStatus(ts taskStatus) (taskState, string) {
	if ts.Data.Status != "stopped" {
		return taskRunning, ""
	}
	if strings.EqualFold(strings.TrimSpace(ts.Data.ExitStatus), "OK") {
		return taskOK, ""
	}
	return taskFailed, ts.Data.ExitStatus
}

// waitTask polls a PVE worker task (identified by its UPID) until it reaches a
// terminal state or ctx is cancelled. It returns nil on a successful ("OK")
// exit status and an error otherwise.
func (c *Client) waitTask(ctx context.Context, upid string) error {
	upid = strings.TrimSpace(upid)
	if upid == "" {
		return errors.New("proxmox: waitTask called with empty UPID")
	}
	node := url.PathEscape(c.cfg.Node)
	statusPath := fmt.Sprintf("/nodes/%s/tasks/%s/status", node, url.PathEscape(upid))

	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("proxmox: wait for task %s: %w", upid, err)
		}

		var ts taskStatus
		if err := c.doJSON(ctx, http.MethodGet, statusPath, nil, &ts); err != nil {
			return fmt.Errorf("proxmox: poll task %s: %w", upid, err)
		}

		switch state, exit := evalTaskStatus(ts); state {
		case taskOK:
			return nil
		case taskFailed:
			return fmt.Errorf("proxmox: task %s failed: exitstatus %q", upid, exit)
		default:
			// still running; wait before the next poll, honouring cancellation.
			select {
			case <-ctx.Done():
				return fmt.Errorf("proxmox: wait for task %s: %w", upid, ctx.Err())
			case <-time.After(taskPollInterval):
			}
		}
	}
}

// nextVMID asks the cluster for the next free VMID.
func (c *Client) nextVMID(ctx context.Context) (int, error) {
	var resp struct {
		Data string `json:"data"`
	}
	if err := c.doJSON(ctx, http.MethodGet, "/cluster/nextid", nil, &resp); err != nil {
		return 0, err
	}
	id, err := strconv.Atoi(strings.TrimSpace(resp.Data))
	if err != nil {
		return 0, fmt.Errorf("proxmox: unexpected nextid %q: %w", resp.Data, err)
	}
	return id, nil
}

// CreateVM implements provider.Provider.
//
// The flow is: allocate a VMID, clone the template (waiting for the clone task
// to finish), grow the primary disk, push CPU/RAM and cloud-init configuration,
// then start the guest (waiting for the start task to finish). Each async PVE
// operation returns a UPID that is polled to completion via waitTask so failures
// surface as errors rather than being silently lost.
func (c *Client) CreateVM(ctx context.Context, spec provider.VMSpec) (provider.VMStatus, error) {
	if spec.TemplateID == 0 {
		return provider.VMStatus{}, errors.New("proxmox: CreateVM requires a non-zero TemplateID")
	}

	newID, err := c.nextVMID(ctx)
	if err != nil {
		return provider.VMStatus{}, err
	}

	node := url.PathEscape(c.cfg.Node)

	// 1. Clone the template into the new VMID, then wait for the clone task.
	cloneForm := url.Values{}
	cloneForm.Set("newid", strconv.Itoa(newID))
	cloneForm.Set("name", spec.Name)
	cloneForm.Set("full", "1")
	var cloneTask taskResponse
	clonePath := fmt.Sprintf("/nodes/%s/qemu/%d/clone", node, spec.TemplateID)
	if err := c.doJSON(ctx, http.MethodPost, clonePath, cloneForm, &cloneTask); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: clone template %d: %w", spec.TemplateID, err)
	}
	if err := c.waitTask(ctx, cloneTask.Data); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: clone template %d into %d: %w", spec.TemplateID, newID, err)
	}

	// From here the VM physically exists on the hypervisor. Any later failure
	// (resize/config/start) must NOT leave it orphaned: roll it back with a
	// best-effort delete on a DETACHED context (so a cancelled ctx still cleans
	// up). If even the rollback fails, surface the vm id so the control plane
	// can reconcile/delete it later instead of losing track of it entirely.
	status, err := c.configureAndStart(ctx, node, newID, spec)
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		if derr := c.DeleteVM(cleanupCtx, strconv.Itoa(newID)); derr != nil {
			return provider.VMStatus{ID: strconv.Itoa(newID), State: "error"},
				fmt.Errorf("%w (rollback of vm %d failed: %v)", err, newID, derr)
		}
		return provider.VMStatus{}, err
	}
	return status, nil
}

// configureAndStart performs the post-clone steps (resize, config, start) on an
// already-cloned VM. Separated out so CreateVM can roll the clone back on any
// failure here. Returns the running VM status on success.
func (c *Client) configureAndStart(ctx context.Context, node string, newID int, spec provider.VMSpec) (provider.VMStatus, error) {
	// 2. Grow the primary disk to the requested size. Modern PVE (7.2+/8.x)
	// returns a task UPID from resize; older PVE returns null. Await the task when
	// one is present, so a failed/locked resize (e.g. storage full, or lock
	// contention right after the clone) surfaces as an error instead of the VM
	// being configured, started, and reported "done" with the template disk size
	// — silently giving the customer less disk than they paid for.
	if spec.DiskGB > 0 {
		resizeForm := url.Values{}
		resizeForm.Set("disk", "scsi0")
		resizeForm.Set("size", strconv.Itoa(spec.DiskGB)+"G")
		resizePath := fmt.Sprintf("/nodes/%s/qemu/%d/resize", node, newID)
		var resizeTask taskResponse
		if err := c.doJSON(ctx, http.MethodPut, resizePath, resizeForm, &resizeTask); err != nil {
			return provider.VMStatus{}, fmt.Errorf("proxmox: resize disk on vm %d: %w", newID, err)
		}
		if upid := strings.TrimSpace(resizeTask.Data); upid != "" {
			if err := c.waitTask(ctx, upid); err != nil {
				return provider.VMStatus{}, fmt.Errorf("proxmox: resize disk on vm %d: %w", newID, err)
			}
		}
	}

	// 3. Configure CPU/RAM, cloud-init and networking. Config is synchronous.
	cfgForm := url.Values{}
	if spec.VCPU > 0 {
		cfgForm.Set("cores", strconv.Itoa(spec.VCPU))
	}
	if spec.RAMMB > 0 {
		cfgForm.Set("memory", strconv.Itoa(spec.RAMMB))
	}
	if len(spec.SSHKeys) > 0 {
		cfgForm.Set("sshkeys", encodeProxmoxSSHKeys(spec.SSHKeys))
	}
	if spec.IPConfig != "" {
		cfgForm.Set("ipconfig0", spec.IPConfig)
	}
	if safeBridge(c.cfg.Bridge) {
		net0 := "virtio,bridge=" + c.cfg.Bridge
		if c.cfg.VLAN > 0 && c.cfg.VLAN <= 4094 {
			net0 += ",tag=" + strconv.Itoa(c.cfg.VLAN)
		}
		cfgForm.Set("net0", net0)
	}
	if user, ok := spec.CloudInit["user"]; ok {
		cfgForm.Set("ciuser", user)
	}
	if pass, ok := spec.CloudInit["password"]; ok {
		cfgForm.Set("cipassword", pass)
	}
	cfgPath := fmt.Sprintf("/nodes/%s/qemu/%d/config", node, newID)
	if err := c.doJSON(ctx, http.MethodPost, cfgPath, cfgForm, nil); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: configure vm %d: %w", newID, err)
	}

	// 4. Start the guest and wait for the start task to complete.
	var startTask taskResponse
	startPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/start", node, newID)
	if err := c.doJSON(ctx, http.MethodPost, startPath, url.Values{}, &startTask); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: start vm %d: %w", newID, err)
	}
	if err := c.waitTask(ctx, startTask.Data); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: start vm %d: %w", newID, err)
	}

	return provider.VMStatus{
		ID:    strconv.Itoa(newID),
		State: "provisioning",
	}, nil
}

// DeleteVM implements provider.Provider. It stops the guest (best effort) and
// then destroys it. A missing guest is treated as success.
func (c *Client) DeleteVM(ctx context.Context, id string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	node := url.PathEscape(c.cfg.Node)

	// A destroy on a running VM is rejected ("VM is running"). Stop it first
	// and WAIT for the stop task to finish before deleting.
	if status, _, err := c.currentState(ctx, vmid); err == nil && status != "stopped" {
		stopPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/stop", node, vmid)
		var stopTask taskResponse
		if err := c.doJSON(ctx, http.MethodPost, stopPath, url.Values{}, &stopTask); err == nil {
			_ = c.waitTask(ctx, stopTask.Data)
		}
	}

	delPath := fmt.Sprintf("/nodes/%s/qemu/%d", node, vmid)
	var delTask taskResponse
	if err := c.doJSON(ctx, http.MethodDelete, delPath, nil, &delTask); err != nil {
		// Proxmox returns a non-2xx for an unknown VMID; surface other errors
		// but treat a clear "does not exist" as success.
		if strings.Contains(err.Error(), "does not exist") {
			return nil
		}
		return err
	}
	// Destroy is asynchronous: wait on the returned UPID so callers only see
	// success once the guest is actually gone.
	if err := c.waitTask(ctx, delTask.Data); err != nil {
		return fmt.Errorf("proxmox: destroy vm %d: %w", vmid, err)
	}
	return nil
}

// currentState reads the guest's lifecycle status and qmpstatus (the latter
// distinguishes a paused guest, whose status stays "running").
func (c *Client) currentState(ctx context.Context, vmid int) (status, qmp string, err error) {
	node := url.PathEscape(c.cfg.Node)
	path := fmt.Sprintf("/nodes/%s/qemu/%d/status/current", node, vmid)
	var cur vmCurrentStatus
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &cur); err != nil {
		return "", "", err
	}
	return cur.Data.Status, cur.Data.QmpStatus, nil
}

// powerOp issues a status/{op} action and waits for the resulting task.
func (c *Client) powerOp(ctx context.Context, vmid int, op string) error {
	node := url.PathEscape(c.cfg.Node)
	path := fmt.Sprintf("/nodes/%s/qemu/%d/status/%s", node, vmid, op)
	var task taskResponse
	if err := c.doJSON(ctx, http.MethodPost, path, url.Values{}, &task); err != nil {
		return fmt.Errorf("proxmox: %s vm %d: %w", op, vmid, err)
	}
	if err := c.waitTask(ctx, task.Data); err != nil {
		return fmt.Errorf("proxmox: %s vm %d: %w", op, vmid, err)
	}
	return nil
}

// PowerOn implements provider.Provider; idempotent if the guest already runs.
func (c *Client) PowerOn(ctx context.Context, id string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	status, _, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "running" {
		return nil
	}
	return c.powerOp(ctx, vmid, "start")
}

// PowerOff implements provider.Provider; idempotent if already stopped.
func (c *Client) PowerOff(ctx context.Context, id string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	status, _, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "stopped" {
		return nil
	}
	return c.powerOp(ctx, vmid, "stop")
}

// Suspend implements provider.Provider (suspend-to-RAM); idempotent if paused.
func (c *Client) Suspend(ctx context.Context, id string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	status, qmp, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if qmp == "paused" {
		return nil
	}
	if status != "running" {
		return fmt.Errorf("proxmox: suspend vm %d: not running (status=%s)", vmid, status)
	}
	return c.powerOp(ctx, vmid, "suspend")
}

// Resume implements provider.Provider; idempotent if already running.
func (c *Client) Resume(ctx context.Context, id string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	status, qmp, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "running" && qmp != "paused" {
		return nil
	}
	return c.powerOp(ctx, vmid, "resume")
}

// vmCurrentStatus mirrors GET /nodes/{node}/qemu/{id}/status/current.
type vmCurrentStatus struct {
	Data struct {
		Status    string `json:"status"`
		QmpStatus string `json:"qmpstatus"`
	} `json:"data"`
}

// vmAgentIfaces mirrors the QEMU guest-agent network-interface query.
type vmAgentIfaces struct {
	Data struct {
		Result []struct {
			Name    string `json:"name"`
			IPAddrs []struct {
				Type    string `json:"ip-address-type"`
				Address string `json:"ip-address"`
			} `json:"ip-addresses"`
		} `json:"result"`
	} `json:"data"`
}

// StatusVM implements provider.Provider. It reports lifecycle state and, when
// the guest agent is available, the primary non-loopback IPv4 address.
func (c *Client) StatusVM(ctx context.Context, id string) (provider.VMStatus, error) {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	node := url.PathEscape(c.cfg.Node)

	var cur vmCurrentStatus
	statusPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/current", node, vmid)
	if err := c.doJSON(ctx, http.MethodGet, statusPath, nil, &cur); err != nil {
		return provider.VMStatus{}, err
	}

	st := provider.VMStatus{ID: id, State: cur.Data.Status}
	if st.State == "" {
		st.State = "unknown"
	}

	// Best-effort IP discovery via the guest agent; failures are ignored.
	var ifaces vmAgentIfaces
	agentPath := fmt.Sprintf("/nodes/%s/qemu/%d/agent/network-get-interfaces", node, vmid)
	if err := c.doJSON(ctx, http.MethodGet, agentPath, nil, &ifaces); err == nil {
		st.IP = firstIPv4(ifaces)
	}
	return st, nil
}

// findGuestByName scans a decoded guest list for an entry whose name matches
// name exactly and returns its VMID, status and whether a match was found. It is
// a pure helper, split out of FindByName so the name-matching logic can be
// unit-tested without a live PVE.
func findGuestByName(guests []guestEntry, name string) (vmid int, status string, found bool) {
	// An empty query never matches: a nameless guest must not be treated as a
	// match for an "unset" name (which would make idempotency dangerously broad).
	if name == "" {
		return 0, "", false
	}
	for _, g := range guests {
		if g.Name == name {
			return g.VMID, g.Status, true
		}
	}
	return 0, "", false
}

// FindByName implements provider.Provider. It lists the node's QEMU guests and
// returns the status of the one whose name matches name. The boolean is false
// (with a zero VMStatus) when no guest carries that name; a non-nil error means
// the list query itself failed.
func (c *Client) FindByName(ctx context.Context, name string) (provider.VMStatus, bool, error) {
	var gl guestList
	listPath := "/nodes/" + url.PathEscape(c.cfg.Node) + "/qemu"
	if err := c.doJSON(ctx, http.MethodGet, listPath, nil, &gl); err != nil {
		return provider.VMStatus{}, false, fmt.Errorf("proxmox: list guests for name %q: %w", name, err)
	}

	vmid, status, found := findGuestByName(gl.Data, name)
	if !found {
		return provider.VMStatus{}, false, nil
	}
	if status == "" {
		status = "unknown"
	}
	return provider.VMStatus{ID: strconv.Itoa(vmid), State: status}, true, nil
}

// firstIPv4 returns the first non-loopback IPv4 address from a guest-agent
// interface listing, or "" if none is found.
func firstIPv4(ifaces vmAgentIfaces) string {
	for _, ifc := range ifaces.Data.Result {
		for _, addr := range ifc.IPAddrs {
			if addr.Type == "ipv4" && addr.Address != "" && !strings.HasPrefix(addr.Address, "127.") {
				return addr.Address
			}
		}
	}
	return ""
}

// encodeProxmoxSSHKeys renders SSH public keys for Proxmox's `sshkeys` config
// parameter. PVE expects the value RFC3986 percent-encoded and rejects the
// form-style '+' that url.QueryEscape emits for spaces, so spaces are rewritten
// to %20. The HTTP form encoder then double-encodes this, which PVE unwinds (it
// form-decodes the body once, then percent-decodes the sshkeys value once),
// recovering the original keys. Trailing whitespace is trimmed so a stray
// newline can't trip PVE's "Parameter verification failed" check.
func encodeProxmoxSSHKeys(keys []string) string {
	joined := strings.TrimSpace(strings.Join(keys, "\n"))
	return strings.ReplaceAll(url.QueryEscape(joined), "+", "%20")
}
