"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, MapPin, Plus, RefreshCw } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, parseApiError, type AdminRegion } from "@/lib/api";

function RegiosInner() {
  const { toast } = useToast();
  const [regions, setRegions] = useState<AdminRegion[] | null>(null);
  const [code, setCode] = useState("");
  const [naam, setNaam] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const laden = useCallback(() => {
    adminApi
      .regions()
      .then(setRegions)
      .catch(() => {
        setRegions([]);
        toast({ title: "Fout", description: "Kon de locaties niet laden.", variant: "destructive" });
      });
  }, [toast]);

  useEffect(() => laden(), [laden]);

  const aanmaken = async () => {
    if (!code.trim() || !naam.trim()) {
      toast({ title: "Vul een code en een naam in", variant: "destructive" });
      return;
    }
    setBusy("nieuw");
    try {
      await adminApi.createRegion(code.trim(), naam.trim());
      setCode("");
      setNaam("");
      laden();
      toast({
        title: "Locatie aangemaakt",
        description: "Hij verschijnt in het bestelscherm zodra er een node in staat.",
      });
    } catch (e) {
      toast({
        title: "Niet aangemaakt",
        description: parseApiError(e, "Bestaat die code al?"),
        variant: "destructive",
      });
    } finally {
      setBusy(null);
    }
  };

  const zetAan = async (r: AdminRegion, enabled: boolean) => {
    setBusy(r.id);
    try {
      const bij = await adminApi.updateRegion(r.id, { enabled });
      setRegions((huidig) => (huidig ?? []).map((x) => (x.id === r.id ? { ...x, ...bij } : x)));
      toast({
        title: enabled ? "Locatie open" : "Locatie gesloten",
        description: enabled
          ? "Er kunnen weer nieuwe VPS'en geplaatst worden."
          : "Wat er draait blijft draaien; er komt niets nieuws bij.",
      });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon de locatie niet wijzigen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  };

  if (regions === null) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Locaties</h1>
          <p className="text-muted-foreground">
            Waar klanten hun VPS kunnen laten draaien. Een node hoort bij één locatie; de eigenaar
            van die node bepaalt welke.
          </p>
        </div>
        <Button variant="ghost" size="sm" className="gap-2" onClick={laden}>
          <RefreshCw className="h-4 w-4" /> Vernieuwen
        </Button>
      </div>

      <Card>
        <CardContent className="space-y-4 p-6">
          <h2 className="text-sm font-medium">Nieuwe locatie</h2>
          <div className="grid gap-4 sm:grid-cols-[1fr_2fr_auto] sm:items-end">
            <div className="space-y-1">
              <Label htmlFor="code">Code</Label>
              <Input id="code" placeholder="nl-2" value={code} onChange={(e) => setCode(e.target.value)} />
              <p className="text-xs text-muted-foreground">kort, blijvend — hij staat in bestellingen</p>
            </div>
            <div className="space-y-1">
              <Label htmlFor="naam">Naam</Label>
              <Input id="naam" placeholder="Amsterdam" value={naam} onChange={(e) => setNaam(e.target.value)} />
              <p className="text-xs text-muted-foreground">wat de klant ziet</p>
            </div>
            <Button className="gap-2" disabled={busy === "nieuw"} onClick={aanmaken}>
              {busy === "nieuw" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
              Aanmaken
            </Button>
          </div>
        </CardContent>
      </Card>

      <div className="space-y-3">
        {regions.map((r) => (
          <Card key={r.id}>
            <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
              <div className="flex items-center gap-3">
                <MapPin className="h-4 w-4 text-muted-foreground" />
                <div>
                  <div className="font-medium">
                    {r.name} <span className="font-mono text-xs text-muted-foreground">{r.code}</span>
                  </div>
                  <div className="text-xs text-muted-foreground">
                    {r.node_count === 0
                      ? "geen nodes — deze locatie kan niets leveren en staat niet in het bestelscherm"
                      : `${r.node_count} node${r.node_count === 1 ? "" : "s"}`}
                  </div>
                </div>
              </div>
              <div className="flex items-center gap-2">
                {r.enabled ? (
                  <Badge variant="outline">open</Badge>
                ) : (
                  <Badge variant="secondary">gesloten</Badge>
                )}
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={busy === r.id}
                  onClick={() => zetAan(r, !r.enabled)}
                >
                  {busy === r.id ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : r.enabled ? (
                    "Sluiten"
                  ) : (
                    "Openen"
                  )}
                </Button>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      <p className="text-xs text-muted-foreground">
        Sluiten is geen verwijderen: de VPS&apos;en die er draaien blijven draaien en blijven
        bereikbaar. Er worden alleen geen nieuwe meer geplaatst, ook niet wanneer een klant
        &ldquo;automatisch&rdquo; kiest.
      </p>
    </div>
  );
}

export default function RegiosPagina() {
  return (
    <AdminGuard>
      <RegiosInner />
    </AdminGuard>
  );
}
