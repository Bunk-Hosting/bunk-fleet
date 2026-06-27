"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, PlusCircle, Server } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { VpsCard } from "@/components/vps/vps-card";
import { vpsApi } from "@/lib/api";
import type { Vps } from "@/lib/types";

export default function VpsListPage() {
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchVps() {
      try {
        const response = await vpsApi.list();
        setVpsList(response.data.results);
      } catch {
        // error handled by layout
      } finally {
        setLoading(false);
      }
    }
    fetchVps();
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Mijn VPS&apos;en</h1>
          <p className="text-muted-foreground">
            Beheer en bekijk al je virtuele servers.
          </p>
        </div>
        <Link href="/dashboard/vps/new">
          <Button>
            <PlusCircle className="mr-2 h-4 w-4" />
            Nieuwe VPS
          </Button>
        </Link>
      </div>

      {vpsList.length > 0 ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {vpsList.map((vps) => (
            <VpsCard key={vps.id} vps={vps} />
          ))}
        </div>
      ) : (
        <Card>
          <CardContent className="flex flex-col items-center justify-center py-16">
            <Server className="h-12 w-12 text-muted-foreground mb-4" />
            <h3 className="text-lg font-semibold mb-2">Geen VPS&apos;en gevonden</h3>
            <p className="text-muted-foreground mb-6 text-center">
              Je hebt nog geen VPS&apos;en. Vraag je eerste VPS aan!
            </p>
            <Link href="/dashboard/vps/new">
              <Button>
                <PlusCircle className="mr-2 h-4 w-4" />
                Eerste VPS aanvragen
              </Button>
            </Link>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
