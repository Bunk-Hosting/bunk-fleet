package main

import (
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

func TestCapOffer(t *testing.T) {
	full := provider.Capacity{TotalVCPU: 16, AvailVCPU: 12, TotalRAMMB: 32000, AvailRAMMB: 20000, TotalDiskGB: 500, AvailDiskGB: 400}

	if got := capOffer(full, config.OfferConfig{}); got != full {
		t.Fatalf("zero offer must not change capacity, got %+v", got)
	}

	got := capOffer(full, config.OfferConfig{VCPU: 4, RAMMB: 8000, DiskGB: 100})
	if got.TotalVCPU != 4 || got.AvailVCPU != 4 {
		t.Errorf("vcpu: got total=%d avail=%d want 4/4", got.TotalVCPU, got.AvailVCPU)
	}
	if got.TotalRAMMB != 8000 || got.AvailRAMMB != 8000 {
		t.Errorf("ram: got total=%d avail=%d want 8000/8000", got.TotalRAMMB, got.AvailRAMMB)
	}
	if got.TotalDiskGB != 100 || got.AvailDiskGB != 100 {
		t.Errorf("disk: got total=%d avail=%d want 100/100", got.TotalDiskGB, got.AvailDiskGB)
	}

	if got := capOffer(full, config.OfferConfig{VCPU: 100}); got.TotalVCPU != 16 || got.AvailVCPU != 12 {
		t.Errorf("offer above total must not change avail, got total=%d avail=%d", got.TotalVCPU, got.AvailVCPU)
	}
}
