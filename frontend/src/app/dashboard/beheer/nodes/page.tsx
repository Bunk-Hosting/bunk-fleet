"use client";

import { useEffect, useState } from "react";
import { Loader2, RefreshCw, HardDrive, Trash2, Plus, Copy, Check } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminNode } from "@/lib/api";

const STATUS_VARIANT: Record<string, "default" | "secondary" | "destructive" | "outline"> = {
  online: "default",
  offline: "destructive",
  draining: "secondary",
  pending: "outline",
};

function Bar({ used, total }: { used: number; total: number }) {
  const pct = total > 0 ? Math.min(100, Math.round((used / total) * 100)) : 0;
  return (
    <div className="space-y-1">
      <div className="text-xs text-muted-foreground">{used}/{total}</div>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
        <div className="h-full rounded-full bg-primary" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

function NodesInner() {
  const { toast } = useToast();
  const [nodes, setNodes] = useState<AdminNode[]>([]);
  const [loading, setLoading] = useState(true);

  const [removing, setRemoving] = useState<string | null>(null);
  const [draining, setDraining] = useState<string | null>(null);

  // Het enroll-token komt maar één keer terug van de server; er staat alleen een
  // hash van in de database. Daarom blijft het hier in beeld tot de operator het
  // wegklikt, in plaats van na een toast te verdwijnen.
  const [enroll, setEnroll] = useState<{ install: string; expires_at: string } | null>(null);
  const [minting, setMinting] = useState(false);
  const [copied, setCopied] = useState(false);

  const addNode = async () => {
    setMinting(true);
    try {
      const res = await adminApi.createEnrollToken();
      setEnroll({ install: res.install, expires_at: res.expires_at });
    } catch {
      toast({
        title: "Kon geen token aanmaken",
        description: "Controleer of er een regio bestaat om de node in te plaatsen.",
        variant: "destructive",
      });
    } finally {
      setMinting(false);
    }
  };

  const copyInstall = async () => {
    if (!enroll) return;
    try {
      await navigator.clipboard.writeText(enroll.install);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast({ title: "Kopiëren lukte niet", description: "Selecteer de regel handmatig." });
    }
  };

  const load = () =>
    adminApi
      .nodes()
      .then(setNodes)
      .catch(() => toast({ title: "Fout", description: "Kon nodes niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

  const toggleDrain = async (n: AdminNode) => {
    const closing = n.status !== "draining";
    setDraining(n.id);
    try {
      if (closing) {
        await adminApi.nodeDrain(n.id);
        toast({
          title: "Node afgesloten",
          description: `${n.name} krijgt geen nieuwe VPS'en meer. Wat er draait blijft draaien.`,
        });
      } else {
        await adminApi.nodeResume(n.id);
        toast({ title: "Node weer in gebruik", description: n.name });
      }
      await load();
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: closing ? "Afsluiten mislukt" : "Heropenen mislukt",
        description:
          status === 409
            ? "Deze node is offline — die komt vanzelf terug zodra hij weer meldt."
            : "Kon de status niet wijzigen.",
        variant: "destructive",
      });
    } finally {
      setDraining(null);
    }
  };

  const removeNode = async (n: AdminNode) => {
    if (!window.confirm(`Node "${n.name}" definitief verwijderen uit de fleet?`)) return;
    setRemoving(n.id);
    try {
      await adminApi.nodeDelete(n.id);
      toast({ title: "Node verwijderd", description: n.name });
      setNodes((prev) => prev.filter((x) => x.id !== n.id));
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: "Verwijderen mislukt",
        description:
          status === 409
            ? "Deze node host nog VPS'en — verwijder die eerst."
            : "Kon de node niet verwijderen.",
        variant: "destructive",
      });
    } finally {
      setRemoving(null);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Nodes</h1>
          <p className="text-muted-foreground">{nodes.length} nodes — datacenter (gedeeld) en community.</p>
        </div>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" className="gap-2" onClick={load}>
            <RefreshCw className="h-4 w-4" /> Ververs
          </Button>
          <Button size="sm" className="gap-2" onClick={addNode} disabled={minting}>
            {minting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
            Node toevoegen
          </Button>
        </div>
      </div>

      {enroll && (
        <Card className="border-primary/40">
          <CardContent className="space-y-3 p-4">
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 className="font-semibold">Voer dit uit op de nieuwe machine</h2>
                <p className="text-sm text-muted-foreground">
                  Op de hypervisor zelf, als root. Het token werkt één keer en verloopt{" "}
                  {new Date(enroll.expires_at).toLocaleString("nl-NL")}.
                </p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => setEnroll(null)}>
                Sluiten
              </Button>
            </div>
            <div className="flex items-center gap-2 rounded-md bg-muted p-3">
              <code className="flex-1 overflow-x-auto whitespace-pre text-xs">{enroll.install}</code>
              <Button variant="ghost" size="sm" onClick={copyInstall} className="shrink-0">
                {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              Deze regel is nu het enige exemplaar: de server bewaart alleen een hash. Sluit je dit
              venster, dan maak je een nieuw token aan.
            </p>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4">
        {nodes.map((n) => {
          const used = (t: number, a: number) => Math.max(0, t - a);
          return (
            <Card key={n.id}>
              <CardContent className="space-y-3 p-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <HardDrive className="h-4 w-4 text-muted-foreground" />
                    <span className="font-medium">{n.name}</span>
                    <span className="text-xs text-muted-foreground">
                      {n.region ?? "—"} · {n.owner_email ?? "geen kostenplaats"}
                    </span>
                    {/* Draait deze node de huidige agent? Zonder dit is dat alleen
                        te achterhalen door in de binary te zoeken. */}
                    <Badge variant="outline" className="font-mono text-[10px]">
                      {n.agent_version ?? "versie onbekend"}
                    </Badge>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={STATUS_VARIANT[n.status] ?? "outline"}>{n.status}</Badge>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-8 gap-1 px-2 text-xs"
                      title={
                        n.status === "draining"
                          ? "Node weer openstellen voor nieuwe VPS'en"
                          : "Geen nieuwe VPS'en meer plaatsen; wat er draait blijft draaien"
                      }
                      disabled={draining === n.id}
                      onClick={() => toggleDrain(n)}
                    >
                      {draining === n.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : n.status === "draining" ? (
                        "Heropenen"
                      ) : (
                        "Afsluiten"
                      )}
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-8 w-8 p-0 text-destructive hover:text-destructive"
                      title="Node verwijderen"
                      disabled={removing === n.id}
                      onClick={() => removeNode(n)}
                    >
                      {removing === n.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Trash2 className="h-4 w-4" />
                      )}
                    </Button>
                  </div>
                </div>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                  <div>
                    <p className="mb-1 text-xs font-medium">vCPU</p>
                    <Bar used={used(n.total_vcpu, n.available_vcpu)} total={n.total_vcpu} />
                  </div>
                  <div>
                    <p className="mb-1 text-xs font-medium">RAM (GB)</p>
                    <Bar used={Math.round(used(n.total_ram_mb, n.available_ram_mb) / 1024)} total={Math.round(n.total_ram_mb / 1024)} />
                  </div>
                  <div>
                    <p className="mb-1 text-xs font-medium">Schijf (GB)</p>
                    <Bar used={used(n.total_disk_gb, n.available_disk_gb)} total={n.total_disk_gb} />
                  </div>
                </div>
                {n.last_heartbeat_at && (
                  <p className="text-xs text-muted-foreground">
                    Laatste heartbeat: {new Date(n.last_heartbeat_at).toLocaleString("nl-NL")}
                  </p>
                )}
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}

export default function AdminNodesPage() {
  return (
    <AdminGuard>
      <NodesInner />
    </AdminGuard>
  );
}
