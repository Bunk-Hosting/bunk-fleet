"use client";

import { useCallback, useEffect, useState } from "react";
import {
  Loader2,
  HardDrive,
  Server,
  Copy,
  Check,
  Cpu,
  MemoryStick,
  HardDriveDownload,
  Coins,
  RefreshCw,
  Terminal,
  ShieldCheck,
  Wifi,
} from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/components/ui/use-toast";
import {
  hostApi,
  parseApiError,
  type HostNode,
  type HostRegion,
  type EnrollTokenResult,
  type HostEarnings,
} from "@/lib/api";

function StatusPill({ status }: { status: string }) {
  const map: Record<string, string> = {
    online: "bg-green-500/15 text-green-400 border-green-500/30",
    offline: "bg-red-500/15 text-red-400 border-red-500/30",
    draining: "bg-amber-500/15 text-amber-400 border-amber-500/30",
    enrolling: "bg-blue-500/15 text-blue-400 border-blue-500/30",
  };
  const cls = map[status] ?? "bg-muted text-muted-foreground border-border";
  return (
    <span className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium capitalize ${cls}`}>
      {status}
    </span>
  );
}

function Meter({ icon: Icon, label, used, total, unit }: {
  icon: React.ElementType; label: string; used: number; total: number; unit: string;
}) {
  const pct = total > 0 ? Math.min(100, Math.round((used / total) * 100)) : 0;
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <span className="flex items-center gap-1"><Icon className="h-3.5 w-3.5" />{label}</span>
        <span>{used}/{total} {unit}</span>
      </div>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
        <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

export default function HardwarePage() {
  const { toast } = useToast();

  const [loading, setLoading] = useState(true);
  const [isHost, setIsHost] = useState(false);
  const [activating, setActivating] = useState(false);

  const [regions, setRegions] = useState<HostRegion[]>([]);
  const [regionCode, setRegionCode] = useState<string>("");
  const [generating, setGenerating] = useState(false);
  const [token, setToken] = useState<EnrollTokenResult | null>(null);
  const [copied, setCopied] = useState(false);

  const [nodes, setNodes] = useState<HostNode[]>([]);
  const [earnings, setEarnings] = useState<HostEarnings | null>(null);

  const loadHostData = useCallback(async () => {
    try {
      const [regs, ns, earn] = await Promise.all([
        hostApi.regions(),
        hostApi.nodes(),
        hostApi.earnings().catch(() => null),
      ]);
      setRegions(regs);
      setRegionCode((prev) => prev || regs[0]?.code || "");
      setNodes(ns);
      if (earn) setEarnings(earn);
    } catch {
      // non-fatal: the page still renders, nodes just stay empty
    }
  }, []);

  useEffect(() => {
    (async () => {
      try {
        const s = await hostApi.status();
        setIsHost(s.is_host);
        if (s.is_host) await loadHostData();
      } catch {
        // leave as non-host; user can still try to activate
      } finally {
        setLoading(false);
      }
    })();
  }, [loadHostData]);

  // Poll nodes while active so a freshly-enrolled server appears online.
  useEffect(() => {
    if (!isHost) return;
    const t = setInterval(() => {
      hostApi.nodes().then(setNodes).catch(() => {});
    }, 12000);
    return () => clearInterval(t);
  }, [isHost]);

  async function handleActivate() {
    setActivating(true);
    try {
      const r = await hostApi.activate();
      setIsHost(r.is_host);
      await loadHostData();
      toast({ title: "Je bent nu host", description: "Genereer hieronder je install-commando." });
    } catch (err) {
      toast({ variant: "destructive", title: "Activeren mislukt", description: parseApiError(err, "Probeer het later opnieuw.") });
    } finally {
      setActivating(false);
    }
  }

  async function handleGenerate() {
    if (!regionCode) return;
    setGenerating(true);
    try {
      const res = await hostApi.createEnrollToken(regionCode, "community");
      setToken(res);
      setCopied(false);
    } catch (err) {
      toast({ variant: "destructive", title: "Genereren mislukt", description: parseApiError(err, "Kon geen install-commando aanmaken.") });
    } finally {
      setGenerating(false);
    }
  }

  async function copyInstall() {
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token.install);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast({ variant: "destructive", title: "Kopiëren mislukt", description: "Selecteer en kopieer het commando handmatig." });
    }
  }

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6 max-w-4xl">
      <div className="flex items-center gap-3">
        <HardDrive className="h-7 w-7 text-primary" />
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Mijn hardware</h1>
          <p className="text-muted-foreground">Bied je eigen server aan en verdien aan VPS-hosting.</p>
        </div>
      </div>

      {/* Always-visible explainer: what this is, what you need, how it works. */}
      <Card>
        <CardHeader>
          <CardTitle>Hoe werkt dit?</CardTitle>
          <CardDescription>
            Bunk Hosting draait niet op één groot datacenter, maar op een netwerk van servers van gebruikers
            zoals jij. Stel je eigen hardware beschikbaar, dan draait Bunk daar VPS&apos;en op en verdien je
            automatisch tegoed — per seconde dat een VPS op jouw machine draait. Dat tegoed gebruik je weer
            voor je eigen VPS&apos;en, of je laat het uitbetalen.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          <div>
            <p className="mb-3 text-sm font-semibold">Wat heb je nodig?</p>
            <ul className="grid gap-3 sm:grid-cols-2">
              <li className="flex gap-3 rounded-lg border border-border bg-muted/20 p-3">
                <Server className="mt-0.5 h-5 w-5 shrink-0 text-primary" />
                <div>
                  <p className="text-sm font-medium">Een server die altijd aan staat</p>
                  <p className="text-xs text-muted-foreground">
                    Met <span className="font-medium text-foreground">Proxmox</span> of{" "}
                    <span className="font-medium text-foreground">VMware ESXi</span> erop — de software die
                    virtuele machines draait. Een oude pc, thuisserver of NAS met genoeg kracht volstaat.
                  </p>
                </div>
              </li>
              <li className="flex gap-3 rounded-lg border border-border bg-muted/20 p-3">
                <Terminal className="mt-0.5 h-5 w-5 shrink-0 text-primary" />
                <div>
                  <p className="text-sm font-medium">Eén Linux-VM voor de agent</p>
                  <p className="text-xs text-muted-foreground">
                    De Bunk-agent draait in een gewone Linux-VM (bijv. Ubuntu) op je hypervisor — dus
                    niet als root op je Proxmox/ESXi zelf. Veilig en weg te gooien.
                  </p>
                </div>
              </li>
              <li className="flex gap-3 rounded-lg border border-border bg-muted/20 p-3">
                <Cpu className="mt-0.5 h-5 w-5 shrink-0 text-primary" />
                <div>
                  <p className="text-sm font-medium">Wat vrije capaciteit</p>
                  <p className="text-xs text-muted-foreground">
                    Richtlijn: minimaal ~2 vCPU, 4 GB RAM en 40 GB vrije schijf om zinvol mee te draaien.
                    Jij bepaalt hoeveel je deelt; de rest blijft van jou.
                  </p>
                </div>
              </li>
              <li className="flex gap-3 rounded-lg border border-border bg-muted/20 p-3">
                <Wifi className="mt-0.5 h-5 w-5 shrink-0 text-primary" />
                <div>
                  <p className="text-sm font-medium">Internet + hypervisor-toegang</p>
                  <p className="text-xs text-muted-foreground">
                    Een stabiele internetverbinding en de API-gegevens van je Proxmox/ESXi (een tokentje of
                    login) zodat de agent VPS&apos;en kan aanmaken. De installer vraagt hier stap voor stap om.
                  </p>
                </div>
              </li>
            </ul>
          </div>

          <div>
            <p className="mb-3 text-sm font-semibold">In 4 stappen live</p>
            <ol className="space-y-3">
              <li className="flex gap-3">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-bold text-primary">1</span>
                <p className="text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">Activeer host-modus.</span> Eén klik op de
                  knop hieronder — je account mag dan nodes aansluiten. Volledig gratis en vrijblijvend.
                </p>
              </li>
              <li className="flex gap-3">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-bold text-primary">2</span>
                <p className="text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">Genereer je install-commando.</span> Kies de
                  regio waar je server staat; je krijgt één commando dat je kunt kopiëren.
                </p>
              </li>
              <li className="flex gap-3">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-bold text-primary">3</span>
                <p className="text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">Plak het in je Linux-VM</span> (met{" "}
                  <code className="rounded bg-muted px-1 py-0.5 text-xs">sudo</code>). De installer downloadt de
                  Bunk-agent, vraagt of je Proxmox of ESXi gebruikt + je API-gegevens, zet beveiligd netwerk op
                  en registreert je node. Geen handmatige configuratie nodig.
                </p>
              </li>
              <li className="flex gap-3">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/15 text-xs font-bold text-primary">4</span>
                <p className="text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">Klaar.</span> Je node verschijnt hieronder als{" "}
                  <span className="text-green-400">online</span>, krijgt automatisch VPS&apos;en toegewezen en je
                  tegoed begint op te lopen. Je volgt alles live op deze pagina.
                </p>
              </li>
            </ol>
          </div>

          <div className="flex items-start gap-2 rounded-lg border border-primary/20 bg-primary/5 p-3">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
            <p className="text-xs text-muted-foreground">
              <span className="font-medium text-foreground">Jij houdt de controle.</span> De agent draait
              geïsoleerd in een VM, gebruikt alleen de capaciteit die je deelt, en je kunt een node op elk
              moment laten leeglopen (draining) of loskoppelen.
            </p>
          </div>
        </CardContent>
      </Card>

      {!isHost ? (
        <Card>
          <CardHeader>
            <CardTitle>Klaar om te beginnen?</CardTitle>
            <CardDescription>
              Activeer host-modus om nodes aan te kunnen sluiten. Gratis en vrijblijvend — je kunt later altijd
              weer stoppen. Hierna verschijnen de stappen om je install-commando te genereren.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button onClick={handleActivate} disabled={activating} className="gap-2">
              {activating ? <Loader2 className="h-4 w-4 animate-spin" /> : <Server className="h-4 w-4" />}
              Activeer host-modus
            </Button>
          </CardContent>
        </Card>
      ) : (
        <>
          {/* 1. Generate install command */}
          <Card>
            <CardHeader>
              <CardTitle>1. Genereer je install-commando</CardTitle>
              <CardDescription>Kies de regio waarin je node draait.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="flex flex-wrap items-end gap-3">
                <div className="space-y-2">
                  <Label>Regio</Label>
                  <Select value={regionCode} onValueChange={setRegionCode}>
                    <SelectTrigger className="w-56"><SelectValue placeholder="Kies een regio" /></SelectTrigger>
                    <SelectContent>
                      {regions.map((r) => (
                        <SelectItem key={r.code} value={r.code}>{r.name} ({r.code})</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <Button onClick={handleGenerate} disabled={generating || !regionCode} className="gap-2">
                  {generating ? <Loader2 className="h-4 w-4 animate-spin" /> : <HardDrive className="h-4 w-4" />}
                  Genereer install-commando
                </Button>
              </div>

              {token && (
                <div className="space-y-3 rounded-lg border border-border bg-muted/30 p-4">
                  <div className="flex items-center justify-between">
                    <p className="text-sm font-medium">Draai dit op een Linux-VM (met sudo) die je hypervisor kan bereiken:</p>
                    <Button variant="outline" size="sm" className="gap-2" onClick={copyInstall}>
                      {copied ? <Check className="h-4 w-4 text-green-400" /> : <Copy className="h-4 w-4" />}
                      {copied ? "Gekopieerd" : "Kopieer"}
                    </Button>
                  </div>
                  <pre className="overflow-x-auto rounded-md bg-background p-3 text-xs leading-relaxed text-foreground">
{token.install}
                  </pre>
                  <p className="text-xs text-muted-foreground">
                    De wizard vraagt je hypervisor (Proxmox of ESXi) en API-gegevens. Token verloopt op{" "}
                    {new Date(token.expires_at).toLocaleString("nl-NL")}.
                  </p>
                </div>
              )}
            </CardContent>
          </Card>

          {/* 2. Nodes */}
          <Card>
            <CardHeader>
              <div className="flex items-center justify-between">
                <div>
                  <CardTitle>Mijn nodes</CardTitle>
                  <CardDescription>Servers die je hebt aangesloten.</CardDescription>
                </div>
                <Button variant="ghost" size="sm" className="gap-2"
                  onClick={() => hostApi.nodes().then(setNodes).catch(() => {})}>
                  <RefreshCw className="h-4 w-4" /> Ververs
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {nodes.length === 0 ? (
                <p className="py-6 text-center text-sm text-muted-foreground">
                  Nog geen nodes. Draai het install-commando hierboven op je server — hij verschijnt
                  hier zodra hij verbinding maakt.
                </p>
              ) : (
                <div className="space-y-3">
                  {nodes.map((n) => (
                    <div key={n.id} className="rounded-lg border border-border p-4 space-y-3">
                      <div className="flex items-center justify-between">
                        <div className="flex items-center gap-2">
                          <Server className="h-4 w-4 text-muted-foreground" />
                          <span className="font-medium">{n.name}</span>
                          <span className="text-xs text-muted-foreground">{n.region ?? "—"} · {n.hypervisor} · {n.tier}</span>
                        </div>
                        <StatusPill status={n.status} />
                      </div>
                      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                        <Meter icon={Cpu} label="vCPU" used={n.total_vcpu - n.available_vcpu} total={n.total_vcpu} unit="" />
                        <Meter icon={MemoryStick} label="RAM" used={Math.round((n.total_ram_mb - n.available_ram_mb) / 1024)} total={Math.round(n.total_ram_mb / 1024)} unit="GB" />
                        <Meter icon={HardDriveDownload} label="Schijf" used={n.total_disk_gb - n.available_disk_gb} total={n.total_disk_gb} unit="GB" />
                      </div>
                      {n.last_heartbeat_at && (
                        <p className="text-xs text-muted-foreground">
                          Laatste heartbeat: {new Date(n.last_heartbeat_at).toLocaleString("nl-NL")}
                        </p>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>

          {/* 3. Earnings */}
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2"><Coins className="h-5 w-5 text-primary" /> Verdiensten</CardTitle>
              <CardDescription>Wat je nodes de laatste 30 dagen hebben opgeleverd.</CardDescription>
            </CardHeader>
            <CardContent>
              {earnings ? (
                <div className="flex flex-wrap gap-8">
                  <div>
                    <p className="text-3xl font-bold">€ {earnings.amount}</p>
                    <p className="text-xs text-muted-foreground">uit te keren (laatste 30 dagen)</p>
                  </div>
                  <div>
                    <p className="text-3xl font-bold">{Math.round(earnings.seconds / 3600)}</p>
                    <p className="text-xs text-muted-foreground">gehoste VPS-uren</p>
                  </div>
                </div>
              ) : (
                <p className="text-sm text-muted-foreground">Nog geen verdiensten — die verschijnen zodra je nodes VPS&apos;en hosten.</p>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
