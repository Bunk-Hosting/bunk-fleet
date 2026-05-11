"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import {
  Users,
  Server,
  Activity,
  PauseCircle,
  AlertTriangle,
  ArrowRight,
  Loader2,
} from "lucide-react";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import type { AdminStats } from "@/lib/types";

export default function AdminDashboardPage() {
  const [stats, setStats] = useState<AdminStats | null>(null);
  const [loading, setLoading] = useState(true);
  const { toast } = useToast();

  useEffect(() => {
    async function fetchStats() {
      try {
        const response = await adminApi.stats();
        setStats(response.data);
      } catch {
        toast({
          title: "Fout",
          description: "Kon statistieken niet ophalen.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    fetchStats();
  }, [toast]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const statCards = [
    {
      title: "Totaal Gebruikers",
      value: stats?.total_users ?? 0,
      icon: Users,
      accent: "",
    },
    {
      title: "Totaal VPS'en",
      value: stats?.total_vps ?? 0,
      icon: Server,
      accent: "",
    },
    {
      title: "Actieve VPS'en",
      value: stats?.active_vps ?? 0,
      icon: Activity,
      accent: "text-green-600",
    },
    {
      title: "Gestopte VPS'en",
      value: stats?.stopped_vps ?? 0,
      icon: PauseCircle,
      accent: "text-muted-foreground",
    },
    {
      title: "VPS'en met Fouten",
      value: stats?.error_vps ?? 0,
      icon: AlertTriangle,
      accent: "text-red-600",
    },
  ];

  return (
    <div className="space-y-8">
      <h1 className="text-3xl font-bold">Admin Dashboard</h1>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
        {statCards.map((card) => (
          <Card key={card.title}>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">
                {card.title}
              </CardTitle>
              <card.icon
                className={`h-5 w-5 ${card.accent || "text-muted-foreground"}`}
              />
            </CardHeader>
            <CardContent>
              <div className={`text-3xl font-bold ${card.accent}`}>
                {card.value}
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Link href="/dashboard/beheer/users">
          <Card className="cursor-pointer transition-colors hover:bg-muted/50">
            <CardHeader className="flex flex-row items-center justify-between">
              <CardTitle className="text-base">Gebruikers beheren</CardTitle>
              <ArrowRight className="h-5 w-5 text-muted-foreground" />
            </CardHeader>
          </Card>
        </Link>
        <Link href="/dashboard/beheer/vps">
          <Card className="cursor-pointer transition-colors hover:bg-muted/50">
            <CardHeader className="flex flex-row items-center justify-between">
              <CardTitle className="text-base">VPS beheren</CardTitle>
              <ArrowRight className="h-5 w-5 text-muted-foreground" />
            </CardHeader>
          </Card>
        </Link>
        <Link href="/dashboard/beheer/logs">
          <Card className="cursor-pointer transition-colors hover:bg-muted/50">
            <CardHeader className="flex flex-row items-center justify-between">
              <CardTitle className="text-base">Auditlogs bekijken</CardTitle>
              <ArrowRight className="h-5 w-5 text-muted-foreground" />
            </CardHeader>
          </Card>
        </Link>
      </div>
    </div>
  );
}
