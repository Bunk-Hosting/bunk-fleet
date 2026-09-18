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

// TestFindGuestByName is a table-driven check of the name-matching logic used
// by FindByName, exercised against the same guestEntry shape that PVE returns
// from GET /nodes/{node}/qemu, without requiring a live Proxmox node.
func TestFindGuestByName(t *testing.T) {
	guests := []guestEntry{
		{VMID: 101, Name: "web-01", Status: "running"},
		{VMID: 102, Name: "db-01", Status: "stopped"},
		{VMID: 103, Name: "", Status: "running"}, // unnamed guest
	}

	tests := []struct {
		name       string
		guests     []guestEntry
		query      string
		wantVMID   int
		wantStatus string
		wantFound  bool
	}{
		{
			name:       "match running guest",
			guests:     guests,
			query:      "web-01",
			wantVMID:   101,
			wantStatus: "running",
			wantFound:  true,
		},
		{
			name:       "match stopped guest",
			guests:     guests,
			query:      "db-01",
			wantVMID:   102,
			wantStatus: "stopped",
			wantFound:  true,
		},
		{
			name:      "no match",
			guests:    guests,
			query:     "cache-01",
			wantFound: false,
		},
		{
			name:      "name match is exact, not substring",
			guests:    guests,
			query:     "web",
			wantFound: false,
		},
		{
			name:      "name match is case-sensitive",
			guests:    guests,
			query:     "WEB-01",
			wantFound: false,
		},
		{
			name:      "empty query never matches (idempotency safety)",
			guests:    guests,
			query:     "",
			wantFound: false, // an unset name must not match an unnamed guest
			wantVMID:  0,
		},
		{
			name:      "empty list",
			guests:    nil,
			query:     "web-01",
			wantFound: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotVMID, gotStatus, gotFound := findGuestByName(tc.guests, tc.query)
			if gotFound != tc.wantFound {
				t.Fatalf("findGuestByName(_, %q) found = %v, want %v", tc.query, gotFound, tc.wantFound)
			}
			if !tc.wantFound {
				return
			}
			if gotVMID != tc.wantVMID {
				t.Errorf("findGuestByName(_, %q) vmid = %d, want %d", tc.query, gotVMID, tc.wantVMID)
			}
			if gotStatus != tc.wantStatus {
				t.Errorf("findGuestByName(_, %q) status = %q, want %q", tc.query, gotStatus, tc.wantStatus)
			}
		})
	}
}

// TestFindGuestByNameFirstMatchWins confirms that when multiple guests share a
// name (which PVE does not normally allow, but the agent must not panic on), the
// first list entry is returned deterministically.
func TestFindGuestByNameFirstMatchWins(t *testing.T) {
	guests := []guestEntry{
		{VMID: 201, Name: "dup", Status: "running"},
		{VMID: 202, Name: "dup", Status: "stopped"},
	}
	vmid, status, found := findGuestByName(guests, "dup")
	if !found || vmid != 201 || status != "running" {
		t.Fatalf("findGuestByName duplicate = (%d, %q, %v), want (201, \"running\", true)", vmid, status, found)
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
	const gib = 1 << 30

	// freeMem wordt nog steeds gezet omdat Proxmox het meestuurt, maar het is
	// bewust niet meer de bron van AvailRAMMB: dat is totaal minus wat draaiende
	// gasten toegewezen hebben. Deze tests laten die twee juist uiteenlopen.
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
			// Zonder gasten is het hele geheugen te vergeven, ook al noemt
			// Proxmox maar 48 GB "free" — de rest zit in page cache en komt vrij
			// zodra een gast hem nodig heeft.
			name: "no guests reports full node",
			ns:   makeNS(16, 64*gib, 48*gib, 500*gib, 400*gib),
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{16, 16, 65536, 65536, 500, 400},
		},
		{
			name: "running guests subtract from avail vcpu and ram",
			ns:   makeNS(16, 64*gib, 48*gib, 500*gib, 400*gib),
			guests: []guestEntry{
				{Status: "running", CPUs: 4, MaxMem: 8 * gib},
				{Status: "running", CPUs: 2, MaxMem: 4 * gib},
				{Status: "stopped", CPUs: 8, MaxMem: 32 * gib}, // ignored
			},
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{16, 10, 65536, 53248, 500, 400},
		},
		{
			name: "oversubscribed avail vcpu and ram clamp at zero",
			ns:   makeNS(4, 16*gib, 4*gib, 100*gib, 10*gib),
			guests: []guestEntry{
				{Status: "running", CPUs: 4, MaxMem: 12 * gib},
				{Status: "running", CPUs: 4, MaxMem: 12 * gib},
			},
			want: struct {
				totalVCPU, availVCPU     int
				totalRAMMB, availRAMMB   int
				totalDiskGB, availDiskGB int
			}{4, 0, 16384, 0, 100, 10},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parseCapacity(tc.ns, tc.guests, 1)
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
	ns.Data.RootFS.Avail = 0        // not provided
	ns.Data.RootFS.Free = 150 * gib // fallback source

	got := parseCapacity(ns, nil, 1)
	if got.AvailDiskGB != 150 {
		t.Fatalf("AvailDiskGB fallback = %d, want 150", got.AvailDiskGB)
	}
}

// Geheugen wordt geteld als toezegging, niet als vrije RAM van de host.
//
// Dit is de fout die op de eerste node zat: de control plane dacht 10,8 GB vrij
// te hebben terwijl er 8 GB aan draaiende gasten was toegewezen. Linux besteedt
// zijn ongebruikte geheugen aan page cache, dus "free" is onbruikbaar laag; wat
// een scheduler nodig heeft is wat er nog te beloven valt.
func TestParseCapacityMemoryCountsRunningGuests(t *testing.T) {
	const mib = 1 << 20
	const gib = 1 << 30

	var ns nodeStatus
	ns.Data.CPUInfo.CPUs = 4
	ns.Data.Memory.Total = 11843 * mib
	ns.Data.Memory.Free = 878 * mib // page cache slokt de rest op
	ns.Data.RootFS.Total = 94 * gib
	ns.Data.RootFS.Avail = 70 * gib

	guests := []guestEntry{
		{VMID: 102, Status: "running", CPUs: 2, MaxMem: 4096 * mib},
		{VMID: 100, Status: "running", CPUs: 1, MaxMem: 512 * mib},
		{VMID: 105, Status: "running", CPUs: 1, MaxMem: 1024 * mib},
		{VMID: 9000, Status: "stopped", CPUs: 2, MaxMem: 2048 * mib},
	}

	got := parseCapacity(ns, guests, 1)

	// 11843 - (4096 + 512 + 1024) = 6211. Niet 878 (free) en niet 11843 (totaal).
	if got.AvailRAMMB != 6211 {
		t.Errorf("AvailRAMMB = %d, want 6211 (totaal minus draaiende gasten)", got.AvailRAMMB)
	}
	if got.TotalRAMMB != 11843 {
		t.Errorf("TotalRAMMB = %d, want 11843", got.TotalRAMMB)
	}
	// Een gestopte gast houdt geen geheugen bezet op de host.
	if got.AvailVCPU != 0 {
		t.Errorf("AvailVCPU = %d, want 0", got.AvailVCPU)
	}
}

// Meer toegewezen dan de machine heeft (overcommit) mag geen negatief getal
// opleveren: dat zou als "heel veel vrij" door de scheduler heen glippen.
func TestParseCapacityMemoryNeverNegative(t *testing.T) {
	const mib = 1 << 20

	var ns nodeStatus
	ns.Data.CPUInfo.CPUs = 2
	ns.Data.Memory.Total = 2048 * mib

	guests := []guestEntry{
		{VMID: 1, Status: "running", CPUs: 4, MaxMem: 4096 * mib},
	}

	got := parseCapacity(ns, guests, 1)
	if got.AvailRAMMB != 0 {
		t.Errorf("AvailRAMMB = %d, want 0 bij overcommit", got.AvailRAMMB)
	}
	if got.AvailVCPU != 0 {
		t.Errorf("AvailVCPU = %d, want 0 bij overcommit", got.AvailVCPU)
	}
}

// LXC-containers tellen net zo hard mee als VM's.
//
// De agent vroeg eerst alleen /nodes/{node}/qemu op. Op de eerste node hielden
// drie containers 2,5 GB vast die daardoor onzichtbaar bleven: hij meldde 6211
// MB vrij terwijl er 3651 te vergeven was. parseCapacity maakt geen onderscheid
// naar soort gast; deze test legt vast dat het ook niet mag.
func TestParseCapacityCountsContainersToo(t *testing.T) {
	const mib = 1 << 20

	var ns nodeStatus
	ns.Data.CPUInfo.CPUs = 4
	ns.Data.Memory.Total = 11843 * mib

	guests := []guestEntry{
		{VMID: 102, Status: "running", CPUs: 2, MaxMem: 4096 * mib}, // VM
		{VMID: 100, Status: "running", CPUs: 1, MaxMem: 512 * mib},  // VM
		{VMID: 105, Status: "running", CPUs: 1, MaxMem: 1024 * mib}, // VM
		{VMID: 101, Status: "running", CPUs: 1, MaxMem: 1024 * mib}, // container
		{VMID: 103, Status: "running", CPUs: 1, MaxMem: 512 * mib},  // container
		{VMID: 104, Status: "running", CPUs: 1, MaxMem: 1024 * mib}, // container
	}

	got := parseCapacity(ns, guests, 1)
	if got.AvailRAMMB != 3651 {
		t.Errorf("AvailRAMMB = %d, want 3651 (VM's én containers afgetrokken)", got.AvailRAMMB)
	}
}

// nodeStatusFor bouwt een nodeStatus voor de tests hieronder. Dezelfde vorm als
// de lokale helper in TestParseCapacity, maar op pakketniveau zodat meer dan een
// test hem kan gebruiken.
func nodeStatusFor(cpus int, totalMem, freeMem, totalDisk, availDisk int64) nodeStatus {
	var ns nodeStatus
	ns.Data.CPUInfo.CPUs = cpus
	ns.Data.Memory.Total = totalMem
	ns.Data.Memory.Free = freeMem
	ns.Data.RootFS.Total = totalDisk
	ns.Data.RootFS.Avail = availDisk
	return ns
}

// Dit is de storing die deze tests bewaken. De control-plane-host heeft vier
// fysieke cores en draait er zelf zeven aan gasten op -- volstrekt normaal, want
// een vCPU is een aandeel in tijd en geen stuk hardware. Toch rekende de agent
// 4 - 7 = 0 vrij, waarna de scheduler nergens meer iets kon plaatsen en elke
// bestelling strandde op 409 no_capacity. RAM blijft wel streng: meer uitdelen
// dan er is betekent dat er iets omvalt.
func TestVCPUMayBeOversubscribedButRAMMayNot(t *testing.T) {
	const gib = 1 << 30

	ns := nodeStatusFor(4, 16*gib, 4*gib, 100*gib, 60*gib)
	guests := []guestEntry{
		{Status: "running", CPUs: 2, MaxMem: 4 * gib},
		{Status: "running", CPUs: 2, MaxMem: 4 * gib},
		{Status: "running", CPUs: 3, MaxMem: 2 * gib},
	}

	got := parseCapacity(ns, guests, 3)

	// 4 cores x 3 = 12 uitdeelbaar, 7 vergeven, 5 over.
	if got.AvailVCPU != 5 {
		t.Errorf("AvailVCPU = %d, want 5", got.AvailVCPU)
	}
	// Het totaal blijft de eerlijke fysieke telling: dat is wat deze machine is.
	if got.TotalVCPU != 4 {
		t.Errorf("TotalVCPU = %d, want 4 (het fysieke aantal)", got.TotalVCPU)
	}
	// RAM ongemoeid: 16 GB totaal, 10 GB vergeven, 6 GB over.
	if got.AvailRAMMB != 6*1024 {
		t.Errorf("AvailRAMMB = %d, want %d", got.AvailRAMMB, 6*1024)
	}
}

func TestVCPUOversubscribeFallsBackToTheDefault(t *testing.T) {
	const gib = 1 << 30

	ns := nodeStatusFor(4, 16*gib, 16*gib, 100*gib, 60*gib)
	guests := []guestEntry{{Status: "running", CPUs: 4, MaxMem: 1 * gib}}

	// Nul of minder is "niet ingesteld", niet "deel niets uit": een node met een
	// lege of ontbrekende instelling moet blijven werken.
	for _, factor := range []int{0, -1} {
		got := parseCapacity(ns, guests, factor)
		want := 4*defaultVCPUOversubscribe - 4
		if got.AvailVCPU != want {
			t.Errorf("factor %d: AvailVCPU = %d, want %d", factor, got.AvailVCPU, want)
		}
	}
}

// Proxmox geeft standaard het laagste vrije nummer vanaf 100, dus klant-VPS'en
// komen tussen de machines van de operator te staan -- op de eerste node van
// deze vloot kreeg een klant-VPS nummer 105, midden tussen 100 tot en met 104.
// Met een bereik blijft Bunk in zijn eigen blok.
func TestFirstFreeVMIDStaysInsideTheRange(t *testing.T) {
	used := map[int]bool{100: true, 101: true, 2000: true, 2001: true, 2003: true}

	got, err := firstFreeVMID(used, 2000, 2999)
	if err != nil {
		t.Fatalf("onverwachte fout: %v", err)
	}
	if got != 2002 {
		t.Errorf("kreeg %d, wil 2002 (het laagste vrije nummer binnen het bereik)", got)
	}
}

func TestFirstFreeVMIDIgnoresWhatIsOutsideTheRange(t *testing.T) {
	// Een druk bezet blok van de operator mag de keuze van Bunk niet beinvloeden.
	used := map[int]bool{}
	for id := 100; id < 1000; id++ {
		used[id] = true
	}

	got, err := firstFreeVMID(used, 2000, 2999)
	if err != nil {
		t.Fatalf("onverwachte fout: %v", err)
	}
	if got != 2000 {
		t.Errorf("kreeg %d, wil 2000", got)
	}
}

func TestFirstFreeVMIDRefusesWhenTheRangeIsFull(t *testing.T) {
	// Buiten het bereik uitwijken zou precies doen wat het bereik moet voorkomen.
	used := map[int]bool{2000: true, 2001: true, 2002: true}

	if _, err := firstFreeVMID(used, 2000, 2002); err == nil {
		t.Error("een vol bereik hoort een fout te geven, geen nummer erbuiten")
	}
}

func TestFirstFreeVMIDHandlesASingleNumber(t *testing.T) {
	if got, err := firstFreeVMID(map[int]bool{}, 2500, 2500); err != nil || got != 2500 {
		t.Errorf("kreeg %d, %v; wil 2500, nil", got, err)
	}
}

// De helpers die ipconfig0 uit elkaar halen bepalen wat er in de firewall
// terechtkomt. Een verkeerd subnet zou óf niets isoleren, óf de gast van zijn
// eigen gateway afsnijden.
func TestIPConfigOntleden(t *testing.T) {
	cases := []struct {
		cfg    string
		ip     string
		gw     string
		subnet string
		waarom string
	}{
		{
			cfg:    "ip=10.10.0.20/19,gw=10.10.0.1",
			ip:     "10.10.0.20",
			gw:     "10.10.0.1",
			subnet: "10.10.0.0/19",
			waarom: "de gewone vorm",
		},
		{
			cfg:    "gw=192.168.1.1,ip=192.168.1.50/24",
			ip:     "192.168.1.50",
			gw:     "192.168.1.1",
			subnet: "192.168.1.0/24",
			waarom: "volgorde mag niet uitmaken",
		},
		{
			cfg:    "ip=dhcp",
			ip:     "dhcp",
			gw:     "",
			subnet: "",
			waarom: "dhcp levert geen bruikbaar subnet; dan liever niets dan iets verkeerds",
		},
		{
			cfg:    "",
			ip:     "",
			gw:     "",
			subnet: "",
			waarom: "leeg blijft leeg",
		},
	}

	for _, c := range cases {
		if got := ipUitIPConfig(c.cfg); got != c.ip {
			t.Errorf("%s: ip = %q, wil %q", c.waarom, got, c.ip)
		}
		if got := gatewayUitIPConfig(c.cfg); got != c.gw {
			t.Errorf("%s: gateway = %q, wil %q", c.waarom, got, c.gw)
		}
		if got := subnetUitIPConfig(c.cfg); got != c.subnet {
			t.Errorf("%s: subnet = %q, wil %q", c.waarom, got, c.subnet)
		}
	}
}

// De omrekening van megabit naar wat Proxmox wil. Acht keer verschil, en dat is
// precies het soort fout dat pas opvalt als een klant klaagt dat zijn 1
// Gbit-pakket een achtste doet.
func TestProxmoxRate(t *testing.T) {
	gevallen := []struct {
		mbit int
		want string
	}{
		{200, "25"},   // Starter
		{500, "62.5"}, // Basic -- geen heel getal, dus niet afronden
		{1000, "125"}, // Pro
		{0, ""},       // geen pakket: geen limiet
		{-1, ""},      // onzin: ook geen limiet
	}

	for _, g := range gevallen {
		if got := proxmoxRate(g.mbit); got != g.want {
			t.Errorf("proxmoxRate(%d) = %q, want %q", g.mbit, got, g.want)
		}
	}
}

// Wat een mens intypt in het dashboard, en wat daarvan gemaakt moet worden.
//
// De aanleiding: iemand typte `https:10.70.0.14:8006` -- de twee schuine strepen
// vergeten -- en kreeg bij elke aanroep "http: no Host in request URL". Die
// melding stond vervolgens in het dashboard als reden waarom de node zijn
// hypervisor niet kon bevragen, en daar is niet uit op te maken dat er twee
// tekens ontbreken.
func TestNormaliseerHost(t *testing.T) {
	goed := []struct{ in, want string }{
		{"https://10.0.0.5:8006", "https://10.0.0.5:8006"},
		{"https://10.0.0.5:8006/", "https://10.0.0.5:8006"},
		{"10.0.0.5:8006", "https://10.0.0.5:8006"},
		{"pve.intern", "https://pve.intern"},
		// De typefout van vandaag.
		{"https:10.70.0.14:8006", "https://10.70.0.14:8006"},
		{"http:10.70.0.14:8006", "http://10.70.0.14:8006"},
		{"  https://10.0.0.5:8006  ", "https://10.0.0.5:8006"},
	}

	for _, g := range goed {
		got, err := normaliseerHost(g.in)
		if err != nil {
			t.Errorf("normaliseerHost(%q) gaf een fout: %v", g.in, err)
			continue
		}
		if got != g.want {
			t.Errorf("normaliseerHost(%q) = %q, want %q", g.in, got, g.want)
		}
	}

	for _, slecht := range []string{"", "   ", "https://", "://8006"} {
		if _, err := normaliseerHost(slecht); err == nil {
			t.Errorf("normaliseerHost(%q) werd geaccepteerd", slecht)
		}
	}
}
