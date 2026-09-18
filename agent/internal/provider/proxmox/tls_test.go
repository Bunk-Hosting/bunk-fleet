package proxmox

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
