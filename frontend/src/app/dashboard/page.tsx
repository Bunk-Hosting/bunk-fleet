"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, Server, ServerOff, PlusCircle, Wallet } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { VpsCard } from "@/components/vps/vps-card";
import { authApi, vpsApi, billingApi } from "@/lib/api";
import { formatEuro } from "@/lib/utils";
import type { User, Vps } from "@/lib/types";

export default function DashboardPage() {
  const [user, setUser] = useState<User | null>(null);
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [balanceCents, setBalanceCents] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchData() {
      try {
        const [userRes, vpsRes] = await Promise.all([
          authApi.me(),
          vpsApi.list(),
        ]);
        setUser(userRes.data);
        setVpsList(vpsRes.data.results);
      } catch {
        // errors handled by layout redirect
      } finally {
        setLoading(false);
      }
      // Wallet is non-critical for the dashboard; load it separately so a
      // hiccup here never blanks the whole page.
      try {
        const walletRes = await billingApi.wallet();
        setBalanceCents(walletRes.data.balance_cents);
      } catch {
        // leave balance unknown
      }
    }
    fetchData();
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  const RECENT_VPS_LIMIT = 5;

  const totalVps = vpsList.length;
  const activeVps = vpsList.filter((v) => v.status === "ACTIVE").length;
  const stoppedVps = vpsList.filter((v) => v.status === "STOPPED").length;
  const recentVps = vpsList.slice(0, RECENT_VPS_LIMIT);

  return (
    <div className="space-y-8">
      {/* Welcome */}
      <div>
        <h1 className="text-3xl font-bold tracking-tight">
          Welkom terug{user ? `, ${user.name}` : ""}
        </h1>
        <p className="text-muted-foreground">
          Hier is een overzicht van je VPS omgeving.
        </p>
      </div>

      {/* Stats cards */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Totaal VPS&apos;en</CardTitle>
            <Server className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{totalVps}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Actieve VPS&apos;en</CardTitle>
            <Server className="h-4 w-4 text-green-500" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-green-600">{activeVps}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Gestopte VPS&apos;en</CardTitle>
            <ServerOff className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{stoppedVps}</div>
          </CardContent>
        </Card>
        <Link href="/dashboard/billing" className="block">
          <Card className="h-full transition-colors hover:border-primary/50">
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Tegoed</CardTitle>
              <Wallet className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">
                {balanceCents === null ? "—" : formatEuro(balanceCents / 100)}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">Opwaarderen →</p>
            </CardContent>
          </Card>
        </Link>
      </div>

      {/* Recent VPS list */}
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-semibold">Recente VPS&apos;en</h2>
          <Link href="/dashboard/vps">
            <Button variant="ghost" size="sm">
              Bekijk alle VPS&apos;en
            </Button>
          </Link>
        </div>

        {recentVps.length > 0 ? (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {recentVps.map((vps) => (
              <VpsCard key={vps.id} vps={vps} />
            ))}
          </div>
        ) : (
          <Card>
            <CardContent className="flex flex-col items-center justify-center py-10">
              <Server className="h-10 w-10 text-muted-foreground mb-4" />
              <p className="text-muted-foreground mb-4">
                Je hebt nog geen VPS&apos;en.
              </p>
              <Link href="/dashboard/vps/new">
                <Button>
                  <PlusCircle className="mr-2 h-4 w-4" />
                  Nieuwe VPS aanvragen
                </Button>
              </Link>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Quick action */}
      {totalVps > 0 && (
        <div>
          <Link href="/dashboard/vps/new">
            <Button>
              <PlusCircle className="mr-2 h-4 w-4" />
              Nieuwe VPS aanvragen
            </Button>
          </Link>
        </div>
      )}
    </div>
  );
}
