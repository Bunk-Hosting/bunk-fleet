package main

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// handleBackupCommand archives a guest's disk, or removes an archive.
//
// Split out from the main command switch because backups are the one kind of
// work a provider may simply not be able to do: ESXi archives guests by a
// different mechanism entirely, so its provider does not implement
// provider.Backups and says so here rather than failing obscurely later.
func handleBackupCommand(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, memos *commandMemos, cmd transport.Command) {
	backups, ok := prov.(provider.Backups)
	if !ok {
		logger.Error("backup: this hypervisor cannot archive guests", "provider", prov.Name())
		reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
			Status: "failed",
			Error:  "backups are not supported on " + prov.Name(),
		})
		return
	}

	var p struct {
		VMID       string `json:"vm_id"`
		VolID      string `json:"volid"`
		StartAfter bool   `json:"start_after"`
	}
	if err := json.Unmarshal(cmd.Payload, &p); err != nil {
		logger.Error("backup: bad payload", "id", cmd.ID, "err", err)
		reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{Status: "failed", Error: err.Error()})
		return
	}

	switch cmd.Kind {
	case transport.CmdBackup:
		logger.Info("backing up vm", "id", cmd.ID, "vm_id", p.VMID)

		archive, err := backups.BackupVM(ctx, p.VMID)
		if err != nil {
			logger.Error("backup failed", "id", cmd.ID, "vm_id", p.VMID, "err", err)
			reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
				Status: "failed", VMID: p.VMID, Error: err.Error(),
			})
			return
		}

		logger.Info("backup done", "id", cmd.ID, "vm_id", p.VMID,
			"volid", archive.VolID, "size_bytes", archive.SizeBytes)
		reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
			Status: "done", VMID: p.VMID, VolID: archive.VolID, SizeBytes: archive.SizeBytes,
		})

	case transport.CmdDeleteBackup:
		logger.Info("deleting backup", "id", cmd.ID, "volid", p.VolID)

		if err := backups.DeleteBackup(ctx, p.VolID); err != nil {
			logger.Error("backup deletion failed", "id", cmd.ID, "volid", p.VolID, "err", err)
			reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
				Status: "failed", Error: err.Error(),
			})
			return
		}

		reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{Status: "done"})

	case transport.CmdRestoreBackup:
		// Loud on purpose: this overwrites a customer's disk, and the log is the
		// only record on the node of when it happened and from what.
		logger.Warn("restoring vm from backup — the current disk will be replaced",
			"id", cmd.ID, "vm_id", p.VMID, "volid", p.VolID)

		if err := backups.RestoreVM(ctx, p.VMID, p.VolID); err != nil {
			logger.Error("restore failed", "id", cmd.ID, "vm_id", p.VMID, "err", err)
			reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
				Status: "failed", VMID: p.VMID, Error: err.Error(),
			})
			return
		}

		if p.StartAfter {
			// The guest was running before; leave it running after. A failure to
			// start is not a failed restore — the disk is back and the customer
			// can start it themselves — but it is worth saying out loud.
			if err := prov.PowerOn(ctx, p.VMID); err != nil {
				logger.Error("restored, but could not start the guest again",
					"id", cmd.ID, "vm_id", p.VMID, "err", err)
				reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{
					Status: "failed", VMID: p.VMID,
					Error: "restored from backup, but starting it again failed: " + err.Error(),
				})
				return
			}
		}

		logger.Info("restore done", "id", cmd.ID, "vm_id", p.VMID, "started", p.StartAfter)
		reportResult(ctx, logger, cp, memos, cmd.ID, transport.CommandResult{Status: "done", VMID: p.VMID})
	}
}
