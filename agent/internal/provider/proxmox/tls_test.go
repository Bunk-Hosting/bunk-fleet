package proxmox

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// Een vastgezette vingerafdruk moet twee dingen doen: het eigen certificaat
// accepteren zonder CA, en elk ander certificaat weigeren. Zonder dat tweede is
// pinnen niet meer dan een omslachtige manier om verificatie uit te zetten.
func TestVastgezetteVingerafdruk(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	ruw := srv.Certificate().Raw
	som := sha256.Sum256(ruw)
	goed := hex.EncodeToString(som[:])

	t.Run("eigen certificaat wordt geaccepteerd", func(t *testing.T) {
		resp, err := httpClient(true, goed).Get(srv.URL)
		if err != nil {
			t.Fatalf("eigen certificaat geweigerd: %v", err)
		}
		_ = resp.Body.Close()
	})

	t.Run("dubbele punten mogen erin staan", func(t *testing.T) {
		met := ""
		for i := 0; i < len(goed); i += 2 {
			if met != "" {
				met += ":"
			}
			met += strings.ToUpper(goed[i : i+2])
		}
		afdruk, err := normaliseerAfdruk(met)
		if err != nil {
			t.Fatalf("vorm met dubbele punten geweigerd: %v", err)
		}
		if afdruk != goed {
			t.Fatalf("afdruk = %q, wil %q", afdruk, goed)
		}
	})

	t.Run("een ander certificaat wordt geweigerd", func(t *testing.T) {
		ander := strings.Repeat("ab", sha256.Size)
		if _, err := httpClient(true, ander).Get(srv.URL); err == nil {
			t.Fatal("een certificaat met een andere vingerafdruk werd geaccepteerd")
		}
	})

	t.Run("zonder afdruk geldt de gewone ketencontrole", func(t *testing.T) {
		// Zelfondertekend, dus dit hoort te falen zolang VerifySSL aan staat.
		if _, err := httpClient(true, "").Get(srv.URL); err == nil {
			t.Fatal("zelfondertekend certificaat kwam door de ketencontrole")
		}
		resp, err := httpClient(false, "").Get(srv.URL)
		if err != nil {
			t.Fatalf("met verificatie uit hoort dit te lukken: %v", err)
		}
		_ = resp.Body.Close()
	})
}

func TestAfdrukVanOnzin(t *testing.T) {
	for _, ruw := range []string{"abc", "zz" + strings.Repeat("aa", 31), strings.Repeat("a", 63)} {
		if _, err := normaliseerAfdruk(ruw); err == nil {
			t.Errorf("%q werd geaccepteerd als vingerafdruk", ruw)
		}
	}
	if afdruk, err := normaliseerAfdruk("  "); err != nil || afdruk != "" {
		t.Errorf("lege waarde = %q, %v; wil geen afdruk en geen fout", afdruk, err)
	}
}

// Een agent op de Proxmox-machine zelf hoort het certificaat van die machine te
// pinnen zonder dat iemand een vingerafdruk hoeft in te typen -- dat is de
// situatie waarin "certificate signed by unknown authority" iedereen overkomt.
func TestAfdrukVanEigenNode(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	defer srv.Close()

	pad := filepath.Join(t.TempDir(), "pve-ssl.pem")
	blok := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	if err := os.WriteFile(pad, blok, 0o600); err != nil {
		t.Fatal(err)
	}
	oud := pveCertPad
	pveCertPad = pad
	defer func() { pveCertPad = oud }()

	som := sha256.Sum256(srv.Certificate().Raw)
	wil := hex.EncodeToString(som[:])

	if got := afdrukVanEigenNode("https://127.0.0.1:8006"); got != wil {
		t.Errorf("loopback: afdruk = %q, wil %q", got, wil)
	}
	if got := afdrukVanEigenNode("https://localhost:8006"); got != wil {
		t.Errorf("localhost: afdruk = %q, wil %q", got, wil)
	}
	// Een ander adres is een andere machine: dan zegt dit bestand niets.
	if got := afdrukVanEigenNode("https://10.70.0.14:8006"); got != "" {
		t.Errorf("adres op afstand: afdruk = %q, wil leeg", got)
	}
}

func TestGeenCertBestand(t *testing.T) {
	oud := pveCertPad
	pveCertPad = filepath.Join(t.TempDir(), "bestaat-niet.pem")
	defer func() { pveCertPad = oud }()

	if got := afdrukVanEigenNode("https://127.0.0.1:8006"); got != "" {
		t.Errorf("afdruk = %q, wil leeg wanneer er geen certificaat ligt", got)
	}
}

// Wat de eigenaar in het dashboard zet hoort te winnen van waarmee de agent
// gestart is -- anders staat er in het paneel iets anders dan er gebeurt.
func TestNetwerkUitInstellingen(t *testing.T) {
	c := &Client{cfg: Config{Bridge: "vmbr0", VLAN: 10}}

	if b, v := c.netwerk(); b != "vmbr0" || v != 10 {
		t.Fatalf("zonder instellingen: %q/%d, wil vmbr0/10", b, v)
	}

	c.ApplySettings(provider.Settings{Bridge: "vmbr2", VLAN: 0, VLANIngesteld: true})
	if b, v := c.netwerk(); b != "vmbr2" || v != 0 {
		t.Fatalf("met instellingen: %q/%d, wil vmbr2/0 (untagged is een keuze)", b, v)
	}

	// Niets ingesteld laat de eigen config staan: een node die niemand heeft
	// aangeraakt mag niet ineens anders gaan doen.
	c.ApplySettings(provider.Settings{})
	if b, v := c.netwerk(); b != "vmbr0" || v != 10 {
		t.Fatalf("leeggemaakt: %q/%d, wil terug naar vmbr0/10", b, v)
	}
}
