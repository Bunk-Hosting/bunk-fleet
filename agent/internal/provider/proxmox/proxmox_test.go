package proxmox

import (
	"encoding/json"
	"testing"
)

// TestEvalTaskStatus is a table-driven check of the UPID task-status decision
// logic used by waitTask. It feeds raw task-status JSON bodies (as PVE returns
// from GET /nodes/{node}/tasks/{upid}/status) through the decoder and asserts
// the distilled outcome, without requiring a live Proxmox node.
func TestEvalTaskStatus(t *testing.T) {
	tests := []struct {
		name      string
		body      string
		wantState taskState
		wantExit  string
	}{
		{
			name:      "still running",
			body:      `{"data":{"status":"running"}}`,
			wantState: taskRunning,
		},
		{
			name:      "stopped without exitstatus yet",
			body:      `{"data":{"status":"stopped"}}`,
			wantState: taskFailed,
			wantExit:  "",
		},
		{
			name:      "stopped OK",
			body:      `{"data":{"status":"stopped","exitstatus":"OK"}}`,
			wantState: taskOK,
		},
		{
			name:      "stopped OK lowercase tolerated",
			body:      `{"data":{"status":"stopped","exitstatus":"ok"}}`,
			wantState: taskOK,
		},
		{
			name:      "stopped with error exit status",
			body:      `{"data":{"status":"stopped","exitstatus":"clone failed: storage full"}}`,
			wantState: taskFailed,
			wantExit:  "clone failed: storage full",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var ts taskStatus
			if err := json.Unmarshal([]byte(tc.body), &ts); err != nil {
				t.Fatalf("unmarshal task status %q: %v", tc.body, err)
			}
			gotState, gotExit := evalTaskStatus(ts)
			if gotState != tc.wantState {
				t.Errorf("evalTaskStatus state = %d, want %d", gotState, tc.wantState)
			}
			if gotExit != tc.wantExit {
				t.Errorf("evalTaskStatus exit = %q, want %q", gotExit, tc.wantExit)
			}
		})
	}
}

func TestAuthHeader(t *testing.T) {
	tests := []struct {
		name    string
		tokenID string
		secret  string
		want    string
	}{
		{
			name:    "standard token",
			tokenID: "root@pam!agent",
			secret:  "11111111-2222-3333-4444-555555555555",
			want:    "PVEAPIToken=root@pam!agent=11111111-2222-3333-4444-555555555555",
		},
		{
			name:    "empty secret still well-formed",
			tokenID: "svc@pve!t",
			secret:  "",
			want:    "PVEAPIToken=svc@pve!t=",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := authHeader(tc.tokenID, tc.secret)
			if got != tc.want {
				t.Fatalf("authHeader(%q, %q) = %q, want %q", tc.tokenID, tc.secret, got, tc.want)
			}
		})
	}
}

func TestParseCapacity(t *testing.T) {
	const mib = 1 << 20
	const gib = 1 << 30

	makeNS := func(cpus int, totalMem, freeMem, totalDisk, availDisk int64) nodeStatus {
		var ns nodeStatus
		ns.Data.CPUInfo.CPUs = cpus
		ns.Data.Memory.Total = totalMem
		ns.Data.Memory.Free = freeMem
		ns.Data.RootFS.Total = totalDisk
		ns.Data.RootFS.Avail = availDisk
		return ns
	}

	tests := []struct {
		name   string
		ns     nodeStatus
		guests []guestEntry
		want   struct {
			totalVCPU, availVCPU     int
			totalRAMMB, availRAMMB   int
			totalDiskGB, availDiskGB int
		}
	}{
		{
			name: "no guests reports full node",
			ns:   makeNS(16, 64*gib, 48*gib, 500*gib, 400*gib),
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{16, 16, 65536, 49152, 500, 400},
		},
		{
			name: "running guests subtract from avail vcpu",
			ns:   makeNS(16, 64*gib, 48*gib, 500*gib, 400*gib),
			guests: []guestEntry{
				{Status: "running", CPUs: 4},
				{Status: "running", CPUs: 2},
				{Status: "stopped", CPUs: 8}, // ignored
			},
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{16, 10, 65536, 49152, 500, 400},
		},
		{
			name: "oversubscribed avail vcpu clamps at zero",
			ns:   makeNS(4, 16*gib, 4*gib, 100*gib, 10*gib),
			guests: []guestEntry{
				{Status: "running", CPUs: 4},
				{Status: "running", CPUs: 4},
			},
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{4, 0, 16384, 4096, 100, 10},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parseCapacity(tc.ns, tc.guests)
			if got.TotalVCPU != tc.want.totalVCPU {
				t.Errorf("TotalVCPU = %d, want %d", got.TotalVCPU, tc.want.totalVCPU)
			}
			if got.AvailVCPU != tc.want.availVCPU {
				t.Errorf("AvailVCPU = %d, want %d", got.AvailVCPU, tc.want.availVCPU)
			}
			if got.TotalRAMMB != tc.want.totalRAMMB {
				t.Errorf("TotalRAMMB = %d, want %d", got.TotalRAMMB, tc.want.totalRAMMB)
			}
			if got.AvailRAMMB != tc.want.availRAMMB {
				t.Errorf("AvailRAMMB = %d, want %d", got.AvailRAMMB, tc.want.availRAMMB)
			}
			if got.TotalDiskGB != tc.want.totalDiskGB {
				t.Errorf("TotalDiskGB = %d, want %d", got.TotalDiskGB, tc.want.totalDiskGB)
			}
			if got.AvailDiskGB != tc.want.availDiskGB {
				t.Errorf("AvailDiskGB = %d, want %d", got.AvailDiskGB, tc.want.availDiskGB)
			}
		})
	}
}

func TestParseCapacityRootFSFreeFallback(t *testing.T) {
	const gib = 1 << 30
	var ns nodeStatus
	ns.Data.RootFS.Total = 200 * gib
	ns.Data.RootFS.Avail = 0       // not provided
	ns.Data.RootFS.Free = 150 * gib // fallback source

	got := parseCapacity(ns, nil)
	if got.AvailDiskGB != 150 {
		t.Fatalf("AvailDiskGB fallback = %d, want 150", got.AvailDiskGB)
	}
}
