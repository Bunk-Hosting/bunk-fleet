// Command bunk-agent is the worker-node agent of the Bunk federated VPS
// hosting platform. It talks to a local hypervisor (Proxmox first), dials out
// to the control plane, enrolls with a one-time token, and reports capacity
// heartbeats on a timer until interrupted.
package main

import (
	"fmt"
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider/esxi"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider/proxmox"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("bunk-agent exited with error", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// Root context cancelled on SIGINT/SIGTERM for graceful shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Build the hypervisor provider.
	prov, err := buildProvider(cfg)
	if err != nil {
		return err
	}
	logger.Info("provider initialized", "provider", prov.Name(), "hypervisor", cfg.Hypervisor)

	// Control-plane client.
	cp := transport.New(cfg.ControlPlaneURL, nil)

	// Credentials: prefer persisted enrollment (survives restarts) over consuming
	// a fresh single-use token; only enroll when no state exists yet.
	statePath := filepath.Join(cfg.StateDir, "state.json")
	if st, ok := loadState(statePath); ok {
		cp.SetCredentials(st.NodeID, st.AgentToken)
		logger.Info("loaded persisted enrollment", "node_id", st.NodeID)
		applyOverlay(logger, st)
	} else if cfg.EnrollToken != "" {
		wgPriv, wgPub, kerr := generateWGKey()
		if kerr != nil {
			logger.Warn("could not generate WireGuard key; overlay disabled", "err", kerr)
		}

		enrollCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		resp, err := cp.Enroll(enrollCtx, cfg.EnrollToken, transport.VpsNetwork{
			Gateway:    cfg.VpsNetwork.Gateway,
			CidrPrefix: cfg.VpsNetwork.CidrPrefix,
			RangeStart: cfg.VpsNetwork.RangeStart,
			RangeEnd:   cfg.VpsNetwork.RangeEnd,
		}, wgPub)
		cancel()
		if err != nil {
			return err
		}
		logger.Info("enrolled with control plane", "node_id", resp.NodeID)

		st := persistedState{
			NodeID:       resp.NodeID,
			AgentToken:   resp.AgentToken,
			WGPrivateKey: wgPriv,
			WGPublicKey:  wgPub,
		}
		if resp.Overlay != nil {
			st.HubPublicKey = resp.Overlay.HubPublicKey
			st.Endpoint = resp.Overlay.Endpoint
			st.OverlayIP = resp.Overlay.OverlayIP
			st.OverlayCIDR = resp.Overlay.OverlayCIDR
		}
		if err := saveState(statePath, st); err != nil {
			logger.Warn("could not persist enrollment; a restart will need a fresh token", "err", err)
		}
		applyOverlay(logger, st)
	} else {
		logger.Warn("no enroll token and no persisted state; heartbeats will fail until credentials are set")
	}

	// Command consumer: long-poll the control plane for provision/delete
	// commands and execute them concurrently with the heartbeat loop. Requires
	// credentials, so it is only started once enrolled.
	if cp.NodeID() != "" {
		cmds, err := cp.Commands(ctx)
		if err != nil {
			return err
		}
		go consumeCommands(ctx, logger, prov, cp, cmds)
		logger.Info("command consumer started")
	} else {
		logger.Warn("not enrolled; command consumer not started")
	}

	// Heartbeat loop.
	ticker := time.NewTicker(cfg.HeartbeatInterval)
	defer ticker.Stop()

	logger.Info("starting heartbeat loop", "interval", cfg.HeartbeatInterval.String())

	// Send an immediate first heartbeat, then on each tick.
	sendHeartbeat(ctx, logger, prov, cp, cfg.Offer)

	for {
		select {
		case <-ctx.Done():
			logger.Info("shutdown signal received, stopping")
			return nil
		case <-ticker.C:
			sendHeartbeat(ctx, logger, prov, cp, cfg.Offer)
		}
	}
}

// buildProvider constructs the hypervisor provider selected by cfg.Hypervisor.
func buildProvider(cfg config.Config) (provider.Provider, error) {
	switch cfg.Hypervisor {
	case "esxi":
		return esxi.New(esxi.Config{
			URL:          cfg.Esxi.URL,
			User:         cfg.Esxi.User,
			Password:     cfg.Esxi.Password,
			Insecure:     cfg.Esxi.Insecure,
			Datacenter:   cfg.Esxi.Datacenter,
			Datastore:    cfg.Esxi.Datastore,
			ResourcePool: cfg.Esxi.ResourcePool,
			Folder:       cfg.Esxi.Folder,
			Template:     cfg.Esxi.Template,
		})
	default:
		return proxmox.New(proxmox.Config{
			Host:        cfg.Proxmox.Host,
			Node:        cfg.Proxmox.Node,
			TokenID:     cfg.Proxmox.TokenID,
			TokenSecret: cfg.Proxmox.TokenSecret,
			VerifySSL:   cfg.Proxmox.VerifySSL,
			Bridge:      cfg.VpsNetwork.Bridge,
			VLAN:        cfg.VpsNetwork.VLAN,
		})
	}
}

// capOffer caps advertised capacity to the operator's chosen offer (0 per
// dimension = unlimited), clamping availability so the scheduler never sees
// more free capacity than is actually offered.
func capOffer(c provider.Capacity, o config.OfferConfig) provider.Capacity {
	if o.VCPU > 0 && c.TotalVCPU > o.VCPU {
		c.TotalVCPU = o.VCPU
	}
	if c.AvailVCPU > c.TotalVCPU {
		c.AvailVCPU = c.TotalVCPU
	}
	if o.RAMMB > 0 && c.TotalRAMMB > o.RAMMB {
		c.TotalRAMMB = o.RAMMB
	}
	if c.AvailRAMMB > c.TotalRAMMB {
		c.AvailRAMMB = c.TotalRAMMB
	}
	if o.DiskGB > 0 && c.TotalDiskGB > o.DiskGB {
		c.TotalDiskGB = o.DiskGB
	}
	if c.AvailDiskGB > c.TotalDiskGB {
		c.AvailDiskGB = c.TotalDiskGB
	}
	return c
}

// sendHeartbeat collects capacity from the provider and reports it to the
// control plane. Errors are logged but never fatal: a single failed heartbeat
// must not take the agent down.
func sendHeartbeat(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, offer config.OfferConfig) {
	hbCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	capacity, err := prov.Capacity(hbCtx)
	if err != nil {
		logger.Error("capacity query failed", "err", err)
		return
	}
	capacity = capOffer(capacity, offer)

	hb := transport.Heartbeat{
		NodeID:      cp.NodeID(),
		At:          time.Now().UTC(),
		TotalVCPU:   capacity.TotalVCPU,
		AvailVCPU:   capacity.AvailVCPU,
		TotalRAMMB:  capacity.TotalRAMMB,
		AvailRAMMB:  capacity.AvailRAMMB,
		TotalDiskGB: capacity.TotalDiskGB,
		AvailDiskGB: capacity.AvailDiskGB,
	}

	if err := cp.SendHeartbeat(hbCtx, hb); err != nil {
		logger.Error("heartbeat send failed", "err", err)
		return
	}
	logger.Info("heartbeat sent",
		"avail_vcpu", capacity.AvailVCPU,
		"avail_ram_mb", capacity.AvailRAMMB,
		"avail_disk_gb", capacity.AvailDiskGB,
	)
}

// consumeCommands drains the command channel until it is closed (on context
// cancellation or a fatal poll error) and dispatches each command. A panic or
// failure handling one command must not stop the loop.
func consumeCommands(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, cmds <-chan transport.Command) {
	for {
		select {
		case <-ctx.Done():
			logger.Info("command consumer stopping", "reason", ctx.Err())
			return
		case cmd, ok := <-cmds:
			if !ok {
				logger.Info("command stream closed")
				return
			}
			handleCommand(ctx, logger, prov, cp, cmd)
		}
	}
}

// handleCommand executes a single dispatched command and reports its outcome to
// the control plane. All errors are turned into a "failed" result; they are
// never propagated so a single bad command cannot take the agent down.
func handleCommand(parentCtx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, cmd transport.Command) {
	// R1: bound every command so a hung hypervisor task (e.g. a stuck PVE clone)
	// can't make a provider call poll forever and wedge the consumer.
	ctx, cancel := context.WithTimeout(parentCtx, 15*time.Minute)
	defer cancel()

	// R5: a panic in any provider/govmomi path must not crash the whole agent
	// (which would kill heartbeats + the command stream). Recover, report the
	// command failed on a DETACHED context, and keep the loop alive.
	defer func() {
		if r := recover(); r != nil {
			rctx, rcancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer rcancel()
			logger.Error("command handler panicked", "id", cmd.ID, "kind", string(cmd.Kind), "panic", r)
			reportResult(rctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: fmt.Sprintf("agent panic: %v", r)})
		}
	}()

	logger.Info("command received", "id", cmd.ID, "kind", string(cmd.Kind))

	switch cmd.Kind {
	case transport.CmdProvision:
		var spec provider.VMSpec
		if err := json.Unmarshal(cmd.Payload, &spec); err != nil {
			logger.Error("provision: bad payload", "id", cmd.ID, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: err.Error()})
			return
		}
		logger.Info("provisioning vm", "id", cmd.ID, "name", spec.Name)

		// Idempotency: the control plane may re-deliver a provision command
		// (e.g. after an agent crash before the result was reported). If a guest
		// with this name already exists, adopt it instead of cloning a duplicate.
		if existing, found, err := prov.FindByName(ctx, spec.Name); err != nil {
			logger.Error("provision: existing-vm lookup failed", "id", cmd.ID, "name", spec.Name, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: err.Error()})
			return
		} else if found {
			// A guest with this name already exists, but FindByName only reports
			// its list-level state and never an IP. A previous attempt may have
			// crashed mid-flight (clone→resize→config→start), leaving the guest
			// stopped or half-configured. Re-check its real state and IP via
			// StatusVM before adopting it, so we never mark a broken VPS active.
			logger.Info("vm already exists (idempotent)", "id", cmd.ID, "name", spec.Name, "vm_id", existing.ID)
			status, err := prov.StatusVM(ctx, existing.ID)
			if err != nil {
				logger.Error("provision: status of existing vm failed", "id", cmd.ID, "vm_id", existing.ID, "err", err)
				reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", VMID: existing.ID, Error: err.Error()})
				return
			}
			if status.State == "running" {
				logger.Info("adopted existing vm", "id", cmd.ID, "vm_id", status.ID, "ip", status.IP)
				reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "done", VMID: status.ID, IP: status.IP})
				return
			}
			// Stopped or half-configured: fail so the control plane drives a clean
			// retry (which can delete and re-provision) rather than adopting it.
			logger.Warn("existing vm not running; not adopting", "id", cmd.ID, "vm_id", status.ID, "state", status.State)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{
				Status: "failed",
				VMID:   status.ID,
				Error:  "existing vm in state " + status.State + " (not running)",
			})
			return
		}

		st, err := prov.CreateVM(ctx, spec)
		if err != nil {
			// st.ID is set when a partial VM could not be rolled back, so the
			// control plane can still reconcile/delete the orphan.
			logger.Error("provision failed", "id", cmd.ID, "vm_id", st.ID, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", VMID: st.ID, Error: err.Error()})
			return
		}
		logger.Info("provision done", "id", cmd.ID, "vm_id", st.ID, "ip", st.IP)
		reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "done", VMID: st.ID, IP: st.IP})

	case transport.CmdDelete:
		var del struct {
			VMID string `json:"vm_id"`
		}
		if err := json.Unmarshal(cmd.Payload, &del); err != nil {
			logger.Error("delete: bad payload", "id", cmd.ID, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: err.Error()})
			return
		}
		logger.Info("deleting vm", "id", cmd.ID, "vm_id", del.VMID)
		if err := prov.DeleteVM(ctx, del.VMID); err != nil {
			logger.Error("delete failed", "id", cmd.ID, "vm_id", del.VMID, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", VMID: del.VMID, Error: err.Error()})
			return
		}
		logger.Info("delete done", "id", cmd.ID, "vm_id", del.VMID)
		reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "done", VMID: del.VMID})

	case transport.CmdStart, transport.CmdStop, transport.CmdPause, transport.CmdResume:
		var p struct {
			VMID string `json:"vm_id"`
		}
		if err := json.Unmarshal(cmd.Payload, &p); err != nil {
			logger.Error("power: bad payload", "id", cmd.ID, "kind", string(cmd.Kind), "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: err.Error()})
			return
		}
		var err error
		switch cmd.Kind {
		case transport.CmdStart:
			err = prov.PowerOn(ctx, p.VMID)
		case transport.CmdStop:
			err = prov.PowerOff(ctx, p.VMID)
		case transport.CmdPause:
			err = prov.Suspend(ctx, p.VMID)
		case transport.CmdResume:
			err = prov.Resume(ctx, p.VMID)
		}
		if err != nil {
			logger.Error("power command failed", "id", cmd.ID, "kind", string(cmd.Kind), "vm_id", p.VMID, "err", err)
			reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", VMID: p.VMID, Error: err.Error()})
			return
		}
		logger.Info("power command done", "id", cmd.ID, "kind", string(cmd.Kind), "vm_id", p.VMID)
		reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "done", VMID: p.VMID})

	default:
		logger.Warn("unknown command kind; ignoring", "id", cmd.ID, "kind", string(cmd.Kind))
		reportResult(ctx, logger, cp, cmd.ID, transport.CommandResult{Status: "failed", Error: "unknown command kind: " + string(cmd.Kind)})
	}
}

// reportResult posts a command outcome with a bounded timeout, logging (but not
// propagating) any reporting failure.
func reportResult(ctx context.Context, logger *slog.Logger, cp *transport.Client, commandID string, res transport.CommandResult) {
	// Use a fresh bounded context so result reporting still runs even if the
	// command's own context is near its deadline; cancellation still propagates
	// from the parent.
	rptCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := cp.ReportResult(rptCtx, commandID, res); err != nil {
		logger.Error("report result failed", "id", commandID, "status", res.Status, "err", err)
	}
}
