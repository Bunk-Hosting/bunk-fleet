"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, HardDrive, Loader2, RefreshCw, Save } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/components/ui/use-toast";
import { nodeApi, parseApiError, type MyNode, type NodeSettings } from "@/lib/api";

// Wat de agent doet als een veld leeg blijft. Dat staat er expliciet bij, want
// "leeg" betekent hier niet nul maar "houd wat er op de machine staat".
const LEEG_BETEKENT = "leeg = ongewijzigd laten";

type Formulier = Record<keyof NodeSettings, string>;

function naarFormulier(s: NodeSettings): Formulier {
  return {
    offer_vcpu: s.offer_vcpu?.toString() ?? "",
    offer_ram_mb: s.offer_ram_mb?.toString() ?? "",
    offer_disk_gb: s.offer_disk_gb?.toString() ?? "",
    vmid_min: s.vmid_min?.toString() ?? "",
    vmid_max: s.vmid_max?.toString() ?? "",
    vcpu_oversubscribe: s.vcpu_oversubscribe?.toString() ?? "",
    guest_name_pattern: s.guest_name_pattern ?? "",
  };
}

// Een leeg getalveld wordt null, niet 0: nul vCPU aanbieden is iets anders dan
// niets ingesteld hebben.
function naarInstellingen(f: Formulier): Partial<NodeSettings> {
  const getal = (v: string) => (v.trim() === "" ? null : Number(v));

  return {
    offer_vcpu: getal(f.offer_vcpu),
    offer_ram_mb: getal(f.offer_ram_mb),
    offer_disk_gb: getal(f.offer_disk_gb),
    vmid_min: getal(f.vmid_min),
    vmid_max: getal(f.vmid_max),
    vcpu_oversubscribe: getal(f.vcpu_oversubscribe),
    guest_name_pattern: f.guest_name_pattern.trim() === "" ? null : f.guest_name_pattern.trim(),
  };
}

function Veld({
  id,
  label,
  hint,
  waarde,
  onChange,
  placeholder,
}: {
  id: string;
  label: string;
  hint: string;
  waarde: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} value={waarde} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
      <p className="text-xs text-muted-foreground">{hint}</p>
    </div>
  );
}

function NodeKaart({ node, onSaved }: { node: MyNode; onSaved: (n: MyNode) => void }) {
  const { toast } = useToast();
  const [form, setForm] = useState<Formulier>(() => naarFormulier(node.settings));
  const [saving, setSaving] = useState(false);

  const zet = (veld: keyof NodeSettings) => (v: string) => setForm((f) => ({ ...f, [veld]: v }));

  const opslaan = async () => {
    setSaving(true);
    try {
      const bijgewerkt = await nodeApi.updateSettings(node.id, naarInstellingen(form));
      onSaved(bijgewerkt);
      setForm(naarFormulier(bijgewerkt.settings));
      toast({
        title: "Opgeslagen",
        description: "De node past dit toe bij zijn volgende heartbeat, binnen een halve minuut.",
      });
    } catch (err) {
      // De server zegt per veld wat er mis is; die tekst is bruikbaarder dan
      // "er ging iets mis", want hij noemt de regel die is overtreden.
      toast({ title: "Niet opgeslagen", description: parseApiError(err, "Controleer de ingevulde waarden."),
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  return (
    <Card>
      <CardContent className="space-y-6 p-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <HardDrive className="h-4 w-4 text-muted-foreground" />
            <span className="font-medium">{node.name}</span>
            <span className="text-xs text-muted-foreground">
              {node.hypervisor} · {node.status}
              {node.agent_version ? ` · agent ${node.agent_version}` : ""}
            </span>
          </div>
          <Button size="sm" className="gap-2" disabled={saving} onClick={opslaan}>
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
            Opslaan
          </Button>
        </div>

        {node.capacity_error && (
          <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-xs">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
            <div>
              <p className="font-medium">De agent kan de hypervisor niet bevragen</p>
              <p className="mt-0.5 break-words text-muted-foreground">{node.capacity_error}</p>
            </div>
          </div>
        )}

        <div>
          <h3 className="text-sm font-medium">Wat er naar de pool gaat</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            Hoeveel van deze machine aan klanten mag worden verkocht. Draait er niets anders op,
            dan kun je dit leeg laten.
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            <Veld id="offer_vcpu" label="vCPU-cores" hint={LEEG_BETEKENT} waarde={form.offer_vcpu} onChange={zet("offer_vcpu")} placeholder="alles" />
            <Veld id="offer_ram_mb" label="RAM (MB)" hint={LEEG_BETEKENT} waarde={form.offer_ram_mb} onChange={zet("offer_ram_mb")} placeholder="alles" />
            <Veld id="offer_disk_gb" label="Schijf (GB)" hint={LEEG_BETEKENT} waarde={form.offer_disk_gb} onChange={zet("offer_disk_gb")} placeholder="alles" />
          </div>
        </div>

        <div>
          <h3 className="text-sm font-medium">Nummers en namen op de hypervisor</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            Proxmox geeft standaard het laagste vrije nummer vanaf 100, waardoor klant-VPS&apos;en
            tussen je eigen machines komen te staan. Met een eigen blok gebeurt dat niet.
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            <Veld id="vmid_min" label="Laagste VMID" hint="bijvoorbeeld 2000" waarde={form.vmid_min} onChange={zet("vmid_min")} placeholder="—" />
            <Veld id="vmid_max" label="Hoogste VMID" hint="bijvoorbeeld 2999" waarde={form.vmid_max} onChange={zet("vmid_max")} placeholder="—" />
            <Veld
              id="vcpu_oversubscribe"
              label="vCPU per core"
              hint="RAM wordt nooit overboekt"
              waarde={form.vcpu_oversubscribe}
              onChange={zet("vcpu_oversubscribe")}
              placeholder="3"
            />
          </div>
          <div className="mt-4">
            <Veld
              id="guest_name_pattern"
              label="Naam van een gast"
              hint="moet {id} bevatten; verder {naam}, {klant} en {node}"
              waarde={form.guest_name_pattern}
              onChange={zet("guest_name_pattern")}
              placeholder="{naam}-{id}"
            />
            <p className="mt-2 text-xs text-muted-foreground">
              Het {"{id}"}-deel is verplicht. De agent herkent aan de naam of hij een machine al
              heeft aangemaakt; zonder uniek deel kunnen twee VPS&apos;en niet uit elkaar worden
              gehouden.
            </p>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

export default function MijnNodesPagina() {
  const { toast } = useToast();
  const [nodes, setNodes] = useState<MyNode[] | null>(null);

  const laden = useCallback(() => {
    nodeApi
      .mine()
      .then(setNodes)
      .catch(() => {
        setNodes([]);
        toast({ title: "Fout", description: "Kon je nodes niet laden.", variant: "destructive" });
      });
  }, [toast]);

  useEffect(() => laden(), [laden]);

  if (nodes === null) {
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
          <h1 className="text-2xl font-bold tracking-tight">Mijn nodes</h1>
          <p className="text-muted-foreground">
            De machines die jij beheert. Een wijziging is binnen een halve minuut actief; je hoeft
            niet op de machine in te loggen.
          </p>
        </div>
        <Button variant="ghost" size="sm" className="gap-2" onClick={laden}>
          <RefreshCw className="h-4 w-4" /> Vernieuwen
        </Button>
      </div>

      {nodes.length === 0 ? (
        <Card>
          <CardContent className="p-6 text-sm text-muted-foreground">
            Je beheert nog geen node. Zet je zelf hardware neer, dan wijst een beheerder hem aan je
            toe — of geef je e-mailadres op tijdens de installatie.
          </CardContent>
        </Card>
      ) : (
        nodes.map((n) => (
          <NodeKaart
            key={n.id}
            node={n}
            onSaved={(bijgewerkt) =>
              setNodes((huidig) => (huidig ?? []).map((x) => (x.id === bijgewerkt.id ? bijgewerkt : x)))
            }
          />
        ))
      )}
    </div>
  );
}
