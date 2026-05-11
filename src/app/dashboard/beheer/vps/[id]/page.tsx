"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Eye, EyeOff, Loader2, Play, Square, Trash2, Copy, Check } from "lucide-react";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { adminApi, vpsApi } from "@/lib/api";
import { formatDateTime, formatPrice, getOsLabel } from "@/lib/utils";
import type { Vps, VpsCredentials, VpsStatus } from "@/lib/types";

const ALL_STATUSES: VpsStatus[] = [
  "PENDING",
  "PROVISIONING",
  "ACTIVE",
  "STOPPED",
  "DELETING",
  "DELETED",
  "ERROR",
];

export default function AdminVpsDetailPage() {
  const params = useParams();
  const router = useRouter();
  const vpsId = Number(params.id);
  const { toast } = useToast();

  const [vps, setVps] = useState<Vps | null>(null);
  const [credentials, setCredentials] = useState<VpsCredentials | null>(null);
  const [credentialsLoading, setCredentialsLoading] = useState(false);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [statusDialogOpen, setStatusDialogOpen] = useState(false);
  const [newStatus, setNewStatus] = useState<VpsStatus>("ACTIVE");
  const [showPassword, setShowPassword] = useState(false);
  const [copied, setCopied] = useState(false);

  const copyPassword = async () => {
    if (!credentials?.sudo_password) return;
    await navigator.clipboard.writeText(credentials.sudo_password);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  useEffect(() => {
    async function fetchVps() {
      try {
        const response = await adminApi.vps.get(vpsId);
        setVps(response.data);
      } catch {
        toast({
          title: "Fout",
          description: "Kon VPS-gegevens niet ophalen.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    fetchVps();
  }, [vpsId, toast]);

  async function handleStart() {
    setActionLoading(true);
    try {
      await adminApi.vps.start(vpsId);
      const response = await adminApi.vps.get(vpsId);
      setVps(response.data);
      toast({ title: "VPS wordt gestart", description: "De VPS wordt opgestart." });
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet starten.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  }

  async function handleStop() {
    setActionLoading(true);
    try {
      await adminApi.vps.stop(vpsId);
      const response = await adminApi.vps.get(vpsId);
      setVps(response.data);
      toast({ title: "VPS wordt gestopt", description: "De VPS wordt gestopt." });
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet stoppen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  }

  async function handleDelete() {
    setActionLoading(true);
    try {
      await adminApi.vps.delete(vpsId);
      toast({
        title: "VPS verwijderd",
        description: "De VPS is succesvol verwijderd.",
      });
      router.push("/dashboard/beheer/vps");
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet verwijderen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
      setDeleteDialogOpen(false);
    }
  }

  async function handleStatusChange() {
    setActionLoading(true);
    try {
      const response = await adminApi.vps.update(vpsId, { status: newStatus });
      setVps(response.data);
      toast({
        title: "Status gewijzigd",
        description: `VPS status is gewijzigd naar ${newStatus}.`,
      });
    } catch {
      toast({
        title: "Fout",
        description: "Kon de status niet wijzigen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
      setStatusDialogOpen(false);
    }
  }

  async function fetchCredentials() {
    if (credentials) {
      setShowPassword((p) => !p);
      return;
    }
    setCredentialsLoading(true);
    try {
      const response = await vpsApi.credentials(vpsId);
      setCredentials(response.data);
      setShowPassword(true);
    } catch {
      toast({
        title: "Fout",
        description: "Kon SSH-gegevens niet ophalen.",
        variant: "destructive",
      });
    } finally {
      setCredentialsLoading(false);
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!vps) {
    return (
      <div className="py-20 text-center text-muted-foreground">
        VPS niet gevonden.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <Link href="/dashboard/beheer/vps">
        <Button variant="ghost" size="sm">
          <ArrowLeft className="mr-2 h-4 w-4" />
          Terug naar VPS beheer
        </Button>
      </Link>

      <div className="flex items-center gap-4">
        <h1 className="text-3xl font-bold">{vps.label}</h1>
        <StatusBadge status={vps.status} />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Algemene informatie</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <p className="text-sm text-muted-foreground">Label</p>
                <p className="font-medium">{vps.label}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Status</p>
                <StatusBadge status={vps.status} />
              </div>
              <div>
                <p className="text-sm text-muted-foreground">OS</p>
                <p className="font-medium">{getOsLabel(vps.os)}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">IP-adres</p>
                <p className="font-medium font-mono">{vps.ip_address ?? "-"}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Hostname</p>
                <p className="font-medium font-mono">{vps.hostname ?? "-"}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Eigenaar</p>
                <p className="font-medium">{vps.owner_email ?? vps.owner}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">vCenter VM ID</p>
                <p className="font-medium font-mono">{vps.vcenter_vm_id ?? "-"}</p>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>SSH gegevens</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <p className="text-sm text-muted-foreground">SSH gebruiker</p>
                <p className="font-medium font-mono">{vps.ssh_username}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">SSH poort</p>
                <p className="font-medium font-mono">{vps.ssh_port}</p>
              </div>
              <div className="sm:col-span-2">
                <p className="text-sm text-muted-foreground">Sudo wachtwoord</p>
                <div className="flex items-center gap-2">
                  <p className="font-medium font-mono tracking-wider">
                    {credentials?.sudo_password
                      ? showPassword
                        ? credentials.sudo_password
                        : "••••••••••••"
                      : "-"}
                  </p>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={fetchCredentials}
                    disabled={credentialsLoading}
                  >
                    {showPassword ? (
                      <EyeOff className="h-4 w-4" />
                    ) : (
                      <Eye className="h-4 w-4" />
                    )}
                  </Button>
                  {credentials?.sudo_password && (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-8 w-8"
                      onClick={copyPassword}
                      title="Kopiëren"
                    >
                      {copied ? (
                        <Check className="h-4 w-4 text-green-500" />
                      ) : (
                        <Copy className="h-4 w-4" />
                      )}
                    </Button>
                  )}
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Pakket specificaties</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <p className="text-sm text-muted-foreground">Pakket</p>
                <p className="font-medium">{vps.package.name}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Prijs</p>
                <p className="font-medium">
                  {formatPrice(vps.package.price_monthly)}/mnd
                </p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">CPU cores</p>
                <p className="font-medium">{vps.package.cpu_cores}</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">RAM</p>
                <p className="font-medium">{vps.package.ram_gb} GB</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Opslag</p>
                <p className="font-medium">{vps.package.disk_gb} GB</p>
              </div>
              <div>
                <p className="text-sm text-muted-foreground">Bandbreedte</p>
                <p className="font-medium">{vps.package.bandwidth_tb} TB</p>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Tijdstempels</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div>
              <p className="text-sm text-muted-foreground">Aangemaakt</p>
              <p className="font-medium">{formatDateTime(vps.created_at)}</p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Laatst bijgewerkt</p>
              <p className="font-medium">{formatDateTime(vps.updated_at)}</p>
            </div>
          </CardContent>
        </Card>
      </div>

      <Separator />

      <Card>
        <CardHeader>
          <CardTitle>Admin acties</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="flex flex-wrap gap-3">
            <Button
              onClick={handleStart}
              disabled={actionLoading || vps.status === "ACTIVE"}
            >
              <Play className="mr-2 h-4 w-4" />
              Starten
            </Button>
            <Button
              variant="secondary"
              onClick={handleStop}
              disabled={actionLoading || vps.status === "STOPPED"}
            >
              <Square className="mr-2 h-4 w-4" />
              Stoppen
            </Button>
            <Button
              variant="destructive"
              onClick={() => setDeleteDialogOpen(true)}
              disabled={actionLoading}
            >
              <Trash2 className="mr-2 h-4 w-4" />
              Verwijderen
            </Button>
          </div>

          <Separator />

          <div className="space-y-3">
            <p className="text-sm font-medium">Status forceren</p>
            <div className="flex flex-wrap items-end gap-3">
              <div className="w-48">
                <Select
                  value={newStatus}
                  onValueChange={(v) => setNewStatus(v as VpsStatus)}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {ALL_STATUSES.map((s) => (
                      <SelectItem key={s} value={s}>
                        {s}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <Button
                variant="outline"
                onClick={() => setStatusDialogOpen(true)}
                disabled={actionLoading}
              >
                Status wijzigen
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>

      <Dialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>VPS verwijderen</DialogTitle>
            <DialogDescription>
              Weet je zeker dat je VPS &quot;{vps.label}&quot; wilt verwijderen?
              Deze actie kan niet ongedaan worden gemaakt.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setDeleteDialogOpen(false)}
              disabled={actionLoading}
            >
              Annuleren
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={actionLoading}
            >
              {actionLoading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Verwijderen
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={statusDialogOpen} onOpenChange={setStatusDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Status wijzigen</DialogTitle>
            <DialogDescription>
              Weet je zeker dat je de status van VPS &quot;{vps.label}&quot; wilt
              wijzigen naar <strong>{newStatus}</strong>? Dit overschrijft de
              huidige status direct.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setStatusDialogOpen(false)}
              disabled={actionLoading}
            >
              Annuleren
            </Button>
            <Button onClick={handleStatusChange} disabled={actionLoading}>
              {actionLoading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Bevestigen
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
