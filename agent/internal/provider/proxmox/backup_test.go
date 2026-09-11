package proxmox

import "testing"

func TestStorageOfPullsTheStorageNameOutOfAVolid(t *testing.T) {
	got, err := storageOf("local:backup/vzdump-qemu-106-2026_09_11-20_15_00.vma.zst")
	if err != nil || got != "local" {
		t.Fatalf("storageOf = %q, %v; want local", got, err)
	}
}

func TestStorageOfRejectsWhatWouldBreakOutOfAnApiPath(t *testing.T) {
	// The result is interpolated into /nodes/x/storage/<here>/content, so a
	// malformed volid is a request somewhere else entirely.
	for _, bad := range []string{
		"",
		"local",
		"local:",
		":backup/x",
		"../../etc:backup/x",
		"has space:backup/x",
	} {
		if _, err := storageOf(bad); err == nil {
			t.Errorf("storageOf accepted %q", bad)
		}
	}
}

func TestBackupStorageFallsBackToLocal(t *testing.T) {
	c := &Client{cfg: Config{}}
	if got := c.backupStorage(); got != "local" {
		t.Errorf("backupStorage = %q, want local", got)
	}

	c = &Client{cfg: Config{BackupStorage: "  "}}
	if got := c.backupStorage(); got != "local" {
		t.Errorf("blank BackupStorage = %q, want local", got)
	}

	c = &Client{cfg: Config{BackupStorage: "nvme-backups"}}
	if got := c.backupStorage(); got != "nvme-backups" {
		t.Errorf("backupStorage = %q, want nvme-backups", got)
	}
}

func TestIsNotFoundOnlyMatchesA404(t *testing.T) {
	// Treating any error as "already gone" would report a failed deletion as a
	// success and leave the archive filling the node's disk.
	if !isNotFound(errString("proxmox: delete backup: status 404: not found")) {
		t.Error("a 404 was not recognised")
	}
	for _, other := range []string{
		"proxmox: delete backup: status 500: internal error",
		"proxmox: delete backup: connection refused",
		"",
	} {
		if isNotFound(errString(other)) {
			t.Errorf("isNotFound matched %q", other)
		}
	}
	if isNotFound(nil) {
		t.Error("isNotFound matched nil")
	}
}

type errString string

func (e errString) Error() string { return string(e) }
