"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Users, Server, HardDrive, Wallet, Loader2, ArrowRight } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminStats } from "@/lib/api";
import { formatEuro } from "@/lib/utils";

function Stat({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return (
    <div className="rounded-lg border p-4">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-2xl font-bold">{value}</p>
      {sub && <p className="mt-1 text-xs text-muted-foreground">{sub}</p>}
    </div>
  );
}

function Overview() {
  const [stats, setStats] = useState<AdminStats | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    adminApi
      .stats()
      .then(setStats)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Beheer</h1>
        <p className="text-muted-foreground">Platform-overzicht en beheer.</p>
      </div>

      {stats && (
        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Users className="h-4 w-4" /> Gebruikers
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/users">Beheren <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.users.total} />
              <Stat label="Klanten" value={stats.users.user} />
              <Stat label="Admins" value={stats.users.admin} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Server className="h-4 w-4" /> VPS&apos;en
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/vps">Beheren <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.vpses.total} />
              <Stat label="Actief" value={stats.vpses.active} />
              <Stat label="Gestopt" value={stats.vpses.stopped} />
              <Stat label="Mislukt" value={stats.vpses.failed} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <HardDrive className="h-4 w-4" /> Nodes
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/nodes">Bekijken <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.nodes.total} />
              <Stat label="Online" value={stats.nodes.online} />
              <Stat label="Datacenter" value={stats.nodes.datacenter} />
              <Stat label="Community" value={stats.nodes.community} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Wallet className="h-4 w-4" /> Tegoed (openstaande verplichting)
              </CardTitle>
            </CardHeader>
            <CardContent>
              <Stat
                label="Totaal klant-tegoed"
                value={formatEuro(stats.credit_outstanding_cents / 100)}
                sub="Som van alle wallet-saldi"
              />
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  );
}

export default function AdminOverviewPage() {
  return (
    <AdminGuard>
      <Overview />
    </AdminGuard>
  );
}
