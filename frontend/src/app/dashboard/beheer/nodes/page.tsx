"use client";

import { useEffect, useState } from "react";
import { Loader2, RefreshCw, HardDrive, Trash2 } from "lucide-react";
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

  const load = () =>
    adminApi
      .nodes()
      .then(setNodes)
      .catch(() => toast({ title: "Fout", description: "Kon nodes niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

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
        <Button variant="ghost" size="sm" className="gap-2" onClick={load}>
          <RefreshCw className="h-4 w-4" /> Ververs
        </Button>
      </div>

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
                      {n.region ?? "—"} · {n.owner_email ?? "gedeeld (datacenter)"}
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={n.tier === "datacenter" ? "default" : "secondary"}>{n.tier}</Badge>
                    <Badge variant={STATUS_VARIANT[n.status] ?? "outline"}>{n.status}</Badge>
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
