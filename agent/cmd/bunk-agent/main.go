// Command bunk-agent is the worker-node agent of the Bunk federated VPS
// hosting platform. It talks to a local hypervisor (Proxmox first), dials out
// to the control plane, enrolls with a one-time token, and reports capacity
// heartbeats on a timer until interrupted.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
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
	prov, err := proxmox.New(proxmox.Config{
		Host:        cfg.Proxmox.Host,
		Node:        cfg.Proxmox.Node,
		TokenID:     cfg.Proxmox.TokenID,
		TokenSecret: cfg.Proxmox.TokenSecret,
		VerifySSL:   cfg.Proxmox.VerifySSL,
	})
	if err != nil {
		return err
	}
	logger.Info("provider initialized", "provider", prov.Name(), "node", cfg.Proxmox.Node)

	// Control-plane client.
	cp := transport.New(cfg.ControlPlaneURL, nil)

	// Enroll if a one-time token was supplied.
	if cfg.EnrollToken != "" {
		enrollCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		resp, err := cp.Enroll(enrollCtx, cfg.EnrollToken)
		cancel()
		if err != nil {
			return err
		}
		logger.Info("enrolled with control plane", "node_id", resp.NodeID)
	} else {
		logger.Warn("no enroll token provided; heartbeats will fail until credentials are set")
	}

	// Heartbeat loop.
	ticker := time.NewTicker(cfg.HeartbeatInterval)
	defer ticker.Stop()

	logger.Info("starting heartbeat loop", "interval", cfg.HeartbeatInterval.String())

	// Send an immediate first heartbeat, then on each tick.
	sendHeartbeat(ctx, logger, prov, cp)

	for {
		select {
		case <-ctx.Done():
			logger.Info("shutdown signal received, stopping")
			return nil
		case <-ticker.C:
			sendHeartbeat(ctx, logger, prov, cp)
		}
	}
}

// sendHeartbeat collects capacity from the provider and reports it to the
// control plane. Errors are logged but never fatal: a single failed heartbeat
// must not take the agent down.
func sendHeartbeat(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client) {
	hbCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	capacity, err := prov.Capacity(hbCtx)
	if err != nil {
		logger.Error("capacity query failed", "err", err)
		return
	}

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
