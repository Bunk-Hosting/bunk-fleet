"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import {
  Loader2,
  ArrowLeft,
  Server,
  Cpu,
  HardDrive,
  Globe,
  Terminal,
  Play,
  Square,
  Trash2,
  Eye,
  EyeOff,
  Copy,
  Check,
  KeyRound,
} from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { vpsApi } from "@/lib/api";
import type { VpsBackup } from "@/lib/api";
import { formatDate, getOsLabel } from "@/lib/utils";
import type { Vps, VpsCredentials, VpsStatus } from "@/lib/types";

const TRANSITIONAL_STATUSES: VpsStatus[] = [
  "PENDING",
  "PROVISIONING",
  // A restore takes minutes and ends by itself; polling is what turns the page
  // back into a working VPS without the customer reloading it.
  "RESTORING",
  "DELETING",
];
const POLL_INTERVAL_MS = 10_000;
const POST_ACTION_POLL_MS = 60_000;

export default function VpsDetailPage() {
  const params = useParams();
  const router = useRouter();
  const { toast } = useToast();

  const id = params.id as string;

  const [vps, setVps] = useState<Vps | null>(null);
  const [credentials, setCredentials] = useState<VpsCredentials | null>(null);
  const [backups, setBackups] = useState<VpsBackup[]>([]);
  const [restoring, setRestoring] = useState<string | null>(null);
  const [confirmRestore, setConfirmRestore] = useState<string | null>(null);
  const [credentialsLoading, setCredentialsLoading] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [copied, setCopied] = useState(false);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [stopDialogOpen, setStopDialogOpen] = useState(false);
  const [startDialogOpen, setStartDialogOpen] = useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [pollUntil, setPollUntil] = useState<number | null>(null);

  const fetchVps = useCallback(
    async (silent = false) => {
      try {
        const response = await vpsApi.get(id);
        setVps(response.data);
      } catch {
        if (!silent) {
          toast({
            title: "Fout",
            description: "Kon VPS gegevens niet laden.",
            variant: "destructive",
          });
        }
      } finally {
        setLoading(false);
      }
    },
    [id, toast]
  );

  const fetchBackups = useCallback(async () => {
    try {
      setBackups(await vpsApi.backups(id));
    } catch {
      // Restore points are a panel on a page, not the page: failing to load them
      // should not bury the rest of it under an error.
    }
  }, [id]);

  const restoreBackup = async (backup: VpsBackup) => {
    setRestoring(backup.id);
    setConfirmRestore(null);
    try {
      await vpsApi.restore(id, backup.id);
      toast({
        title: "Terugzetten gestart",
        description:
          "Je VPS is even niet bereikbaar terwijl de schijf wordt teruggezet. " +
          "Zodra dat klaar is komt hij vanzelf terug.",
      });
      await fetchVps(true);
      await fetchBackups();
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: "Terugzetten mislukt",
        description:
          status === 409
            ? "Deze VPS is nu ergens anders mee bezig. Probeer het zo opnieuw."
            : "Kon het terugzetten niet starten.",
        variant: "destructive",
      });
    } finally {
      setRestoring(null);
    }
  };

  const fetchCredentials = async () => {
    if (credentials) {
      setShowPassword((p) => !p);
      return;
    }
    setCredentialsLoading(true);
    try {
      const response = await vpsApi.credentials(id);
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
  };

  const copyPassword = async () => {
    if (!credentials?.sudo_password) return;
    await navigator.clipboard.writeText(credentials.sudo_password).catch(() => undefined);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  useEffect(() => {
    // Zie dashboard/vps/page.tsx: via een microtask, zodat een synchrone worp
    // niet in dezelfde rendercyclus state zet.
    queueMicrotask(() => {
      fetchVps();
      fetchBackups();
    });
  }, [fetchVps, fetchBackups]);

  // Poll zolang de VPS in een overgangsstatus zit, of kort na een
  // start/stop-actie zodat de nieuwe status zichtbaar wordt.
  const isTransitional =
    vps !== null && TRANSITIONAL_STATUSES.includes(vps.status);
  const shouldPoll = isTransitional || pollUntil !== null;

  useEffect(() => {
    if (!shouldPoll) return;
    const interval = setInterval(() => {
      setPollUntil((until) =>
        until !== null && Date.now() >= until ? null : until
      );
      fetchVps(true);
    }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [shouldPoll, fetchVps]);

  const handleStart = async () => {
    setActionLoading(true);
    try {
      await vpsApi.start(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt gestart.",
      });
      setStartDialogOpen(false);
      setPollUntil(Date.now() + POST_ACTION_POLL_MS);
      await fetchVps();
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet starten.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  const handleStop = async () => {
    setActionLoading(true);
    try {
      await vpsApi.stop(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt gestopt.",
      });
      setStopDialogOpen(false);
      setPollUntil(Date.now() + POST_ACTION_POLL_MS);
      await fetchVps();
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet stoppen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  const handleDelete = async () => {
    setActionLoading(true);
    try {
      await vpsApi.delete(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt verwijderd.",
      });
      setDeleteDialogOpen(false);
      router.push("/dashboard/vps");
    } catch {
      toast({
        title: "Fout",
        description: "Kon de VPS niet verwijderen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!vps) {
    return (
      <div className="text-center py-20">
        <p className="text-muted-foreground">VPS niet gevonden.</p>
        <Button
          variant="link"
          onClick={() => router.push("/dashboard/vps")}
          className="mt-4"
        >
          Terug naar overzicht
        </Button>
      </div>
    );
  }

  const canStop = vps.status === "ACTIVE";
  const canStart = vps.status === "STOPPED";
  const canDelete = vps.status !== "DELETING" && vps.status !== "DELETED";

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      {/* Back button */}
      <Button
        variant="ghost"
        onClick={() => router.push("/dashboard/vps")}
        className="gap-2"
      >
        <ArrowLeft className="h-4 w-4" />
        Terug naar overzicht
      </Button>

      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">
            {vps.label || `VPS #${vps.id}`}
          </h1>
          <div className="mt-2">
            <StatusBadge status={vps.status} />
          </div>
        </div>

        {/* Action buttons */}
        <div className="flex flex-wrap gap-2">
          {/* Terminal button */}
          <Link href={`/dashboard/vps/${id}/terminal`}>
            <Button variant="outline" disabled={vps.status !== "ACTIVE"}>
              <Terminal className="mr-2 h-4 w-4" />
              Terminal
            </Button>
          </Link>

          {/* Start */}
          <ConfirmDialog
            open={startDialogOpen}
            onOpenChange={setStartDialogOpen}
            trigger={
              <Button disabled={!canStart}>
                <Play className="mr-2 h-4 w-4" />
                Starten
              </Button>
            }
            title="VPS starten"
            description="Weet je zeker dat je deze VPS wilt starten?"
            confirmLabel="Starten"
            onConfirm={handleStart}
            loading={actionLoading}
          />

          {/* Stop */}
          <ConfirmDialog
            open={stopDialogOpen}
            onOpenChange={setStopDialogOpen}
            trigger={
              <Button variant="outline" disabled={!canStop}>
                <Square className="mr-2 h-4 w-4" />
                Stoppen
              </Button>
            }
            title="VPS stoppen"
            description="Weet je zeker dat je deze VPS wilt stoppen? De server wordt uitgeschakeld."
            confirmLabel="Stoppen"
            variant="destructive"
            onConfirm={handleStop}
            loading={actionLoading}
          />

          {/* Delete */}
          <ConfirmDialog
            open={deleteDialogOpen}
            onOpenChange={setDeleteDialogOpen}
            trigger={
              <Button variant="destructive" disabled={!canDelete}>
                <Trash2 className="mr-2 h-4 w-4" />
                Verwijderen
              </Button>
            }
            title="VPS verwijderen"
            description="Weet je zeker dat je deze VPS wilt verwijderen? Dit kan niet ongedaan worden gemaakt. Alle gegevens worden permanent verwijderd."
            confirmLabel="Definitief verwijderen"
            variant="destructive"
            onConfirm={handleDelete}
            loading={actionLoading}
          />
        </div>
      </div>

      {/* Detail cards */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* General info */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Server className="h-5 w-5" />
              Algemene informatie
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Label</span>
              <span className="font-medium">
                {vps.label || `VPS #${vps.id}`}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Status</span>
              <StatusBadge status={vps.status} />
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Aangemaakt op</span>
              <span className="font-medium">{formatDate(vps.created_at)}</span>
            </div>
          </CardContent>
        </Card>

        {/* Toegang via webterminal */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Terminal className="h-5 w-5" />
              Toegang
            </CardTitle>
            <CardDescription>
              Verbind met je VPS via de ingebouwde webterminal.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Link href={`/dashboard/vps/${vps.id}/terminal`}>
              <Button className="w-full gap-2" disabled={vps.status !== "ACTIVE"}>
                <Terminal className="h-4 w-4" />
                Webterminal openen
              </Button>
            </Link>
          </CardContent>
        </Card>

        {/* Inloggegevens */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <KeyRound className="h-5 w-5" />
              Inloggegevens
            </CardTitle>
            <CardDescription>
              De snelste manier om in te loggen is de webterminal hierboven. Een
              sudo-wachtwoord verschijnt hier alleen als de server er zelf één
              instelt.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-3">
              {vps.public_host && vps.ssh_port ? (
                <>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">Adres</p>
                    <p className="font-medium font-mono">{vps.public_host}</p>
                  </div>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">Gebruikersnaam</p>
                    <p className="font-medium font-mono">{vps.ssh_username}</p>
                  </div>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">SSH-poort</p>
                    <p className="font-medium font-mono">{vps.ssh_port}</p>
                  </div>
                  <div className="sm:col-span-3 space-y-1">
                    <p className="text-sm text-muted-foreground">Verbinden</p>
                    <p className="font-medium font-mono break-all">
                      ssh -p {vps.ssh_port} {vps.ssh_username}@{vps.public_host}
                    </p>
                  </div>
                </>
              ) : (
                /* Telling someone their VPS lives at 10.10.0.21 is telling them
                   nothing: that address is only routable on the machine the VPS
                   runs on. Better to say plainly that there is no external
                   endpoint yet than to print one that cannot work. */
                <div className="sm:col-span-3 space-y-1">
                  <p className="text-sm text-muted-foreground">Bereikbaar van buiten</p>
                  <p className="font-medium">
                    Nee. Je bereikt deze VPS via de webterminal hierboven — die geeft je
                    een volwaardige shell. SSH vanaf je eigen machine staat bewust uit,
                    zodat de VPS niet aan het open internet hangt.
                  </p>
                </div>
              )}
              <div className="sm:col-span-3 space-y-1">
                <p className="text-sm text-muted-foreground">Sudo-wachtwoord</p>
                <div className="flex items-center gap-2">
                  <p className="font-medium font-mono tracking-wider">
                    {credentials?.sudo_password
                      ? showPassword
                        ? credentials.sudo_password
                        : "••••••••••••"
                      : "—"}
                  </p>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={fetchCredentials}
                    disabled={credentialsLoading}
                    title={showPassword ? "Verbergen" : "Tonen"}
                  >
                    {credentialsLoading ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : showPassword ? (
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

        {/* Specifications */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Cpu className="h-5 w-5" />
              Specificaties
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Pakket</p>
                <p className="font-medium">{vps.package.name}</p>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">vCPU</p>
                <div className="flex items-center gap-2">
                  <Cpu className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.cpu_cores} cores</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">RAM</p>
                <div className="flex items-center gap-2">
                  <HardDrive className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.ram_gb} GB</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Opslag</p>
                <div className="flex items-center gap-2">
                  <HardDrive className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.disk_gb} GB NVMe</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Bandbreedte</p>
                <div className="flex items-center gap-2">
                  <Globe className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.bandwidth_tb} TB</p>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
        {/* Restore points */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <HardDrive className="h-5 w-5" />
              Back-ups
            </CardTitle>
            <CardDescription>
              Elke nacht wordt een kopie van je schijf gemaakt; de laatste twee
              bewaren we. Ze staan op dezelfde machine als je VPS — genoeg om
              terug te gaan als je zelf iets sloopt, niet om een kapotte machine
              te overleven.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {backups.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                Nog geen back-up. De eerste volgt vannacht.
              </p>
            ) : (
              <div className="space-y-2">
                {backups.map((b) => (
                  <div
                    key={b.id}
                    className="flex flex-wrap items-center justify-between gap-2 rounded-md border p-3"
                  >
                    <div className="space-y-0.5">
                      <p className="font-medium">
                        {b.finished_at
                          ? formatDate(b.finished_at)
                          : b.started_at
                            ? `Bezig sinds ${formatDate(b.started_at)}`
                            : "In de wachtrij"}
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {b.status === "failed"
                          ? `Mislukt — ${b.error ?? "onbekende fout"}`
                          : b.size_bytes
                            ? `${(b.size_bytes / 1024 ** 3).toFixed(1)} GB`
                            : "—"}
                      </p>
                    </div>
                    {b.status === "done" && (
                      <ConfirmDialog
                        open={confirmRestore === b.id}
                        onOpenChange={(open) => setConfirmRestore(open ? b.id : null)}
                        trigger={
                          <Button
                            variant="outline"
                            size="sm"
                            disabled={
                              restoring !== null ||
                              !(vps.status === "ACTIVE" || vps.status === "STOPPED")
                            }
                          >
                            {restoring === b.id ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              "Terugzetten"
                            )}
                          </Button>
                        }
                        title="Back-up terugzetten?"
                        description={`Je schijf wordt vervangen door de kopie van ${
                          b.finished_at ? formatDate(b.finished_at) : "deze back-up"
                        }. Alles wat je sindsdien hebt veranderd is weg en komt niet terug.`}
                        confirmLabel="Terugzetten"
                        variant="destructive"
                        loading={restoring === b.id}
                        onConfirm={() => restoreBackup(b)}
                      />
                    )}
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

    </div>
  );
}
