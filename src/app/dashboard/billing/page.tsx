"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { CreditCard, Receipt, ArrowRight, TrendingUp, Calendar, AlertCircle } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Loader2 } from "lucide-react";
import { billingApi } from "@/lib/api";
import type { BillingOverview, Invoice } from "@/lib/types";
import { useToast } from "@/components/ui/use-toast";
import { formatEuro, formatDateLong as formatDate } from "@/lib/utils";

const statusConfig: Record<string, { label: string; variant: "default" | "secondary" | "destructive" | "outline" }> = {
  open: { label: "Openstaand", variant: "destructive" },
  paid: { label: "Betaald", variant: "default" },
  draft: { label: "Concept", variant: "secondary" },
  void: { label: "Vervallen", variant: "outline" },
};

export default function BillingOverviewPage() {
  const { toast } = useToast();
  const [overview, setOverview] = useState<BillingOverview | null>(null);
  const [recentInvoices, setRecentInvoices] = useState<Invoice[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const [overviewRes, invoicesRes] = await Promise.all([
          billingApi.overview(),
          billingApi.invoices.list(),
        ]);
        setOverview(overviewRes.data);
        setRecentInvoices(invoicesRes.data.results.slice(0, 5));
      } catch {
        toast({
          title: "Fout",
          description: "Kon finance-overzicht niet laden.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [toast]);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  const hasOpenInvoices = overview && overview.open_invoice_count > 0;

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Finance</h1>
        <p className="text-muted-foreground">Overzicht van je kosten en facturen.</p>
      </div>

      {/* Openstaand saldo alert */}
      {hasOpenInvoices && (
        <div className="flex items-start gap-3 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
          <div className="text-sm">
            <span className="font-semibold text-destructive">
              {overview.open_invoice_count} openstaande{" "}
              {overview.open_invoice_count === 1 ? "factuur" : "facturen"},{" "}
              {formatEuro(overview.open_amount)} te betalen.
            </span>{" "}
            <Link href="/dashboard/billing/invoices" className="underline underline-offset-2">
              Bekijk facturen
            </Link>
          </div>
        </div>
      )}

      {/* Stats */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Openstaand bedrag
            </CardTitle>
            <CreditCard className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <p className={`text-2xl font-bold ${hasOpenInvoices ? "text-destructive" : ""}`}>
              {formatEuro(overview?.open_amount ?? 0)}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              {overview?.open_invoice_count ?? 0} openstaande facturen
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Maandelijkse kosten
            </CardTitle>
            <TrendingUp className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">
              {formatEuro(overview?.monthly_cost ?? 0)}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              {overview?.active_subscriptions ?? 0} actieve VPS
              {(overview?.active_subscriptions ?? 0) !== 1 ? "'en" : ""}
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Volgende factuur
            </CardTitle>
            <Calendar className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">
              {overview?.next_invoice_date
                ? formatDate(overview.next_invoice_date)
                : "—"}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              Geschatte volgende factuurdatum
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Actieve abonnementen
            </CardTitle>
            <Receipt className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">
              {overview?.active_subscriptions ?? 0}
            </p>
            <p className="text-xs text-muted-foreground mt-1">Lopende VPS-abonnementen</p>
          </CardContent>
        </Card>
      </div>

      {/* Recente facturen */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>Recente facturen</CardTitle>
          <Button variant="ghost" size="sm" asChild>
            <Link href="/dashboard/billing/invoices">
              Alle facturen
              <ArrowRight className="ml-2 h-4 w-4" />
            </Link>
          </Button>
        </CardHeader>
        <CardContent>
          {recentInvoices.length === 0 ? (
            <p className="text-sm text-muted-foreground py-6 text-center">
              Nog geen facturen beschikbaar.
            </p>
          ) : (
            <div className="space-y-3">
              {recentInvoices.map((invoice) => {
                const cfg = statusConfig[invoice.status] ?? { label: invoice.status, variant: "secondary" as const };
                return (
                  <div
                    key={invoice.id}
                    className="flex items-center justify-between rounded-lg border px-4 py-3"
                  >
                    <div className="space-y-0.5">
                      <p className="text-sm font-medium">{invoice.invoice_number}</p>
                      <p className="text-xs text-muted-foreground">
                        {formatDate(invoice.period_start)} t/m {formatDate(invoice.period_end)}
                      </p>
                    </div>
                    <div className="flex items-center gap-4">
                      <p className="text-sm font-semibold">{formatEuro(invoice.total)}</p>
                      <Badge variant={cfg.variant}>{cfg.label}</Badge>
                      <Button variant="ghost" size="sm" asChild>
                        <Link href={`/dashboard/billing/invoices/${invoice.id}`}>
                          Bekijken
                        </Link>
                      </Button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Snelkoppelingen */}
      <div className="flex gap-3">
        <Button variant="outline" asChild>
          <Link href="/dashboard/billing/invoices">
            <Receipt className="mr-2 h-4 w-4" />
            Alle facturen
          </Link>
        </Button>
        <Button variant="outline" asChild>
          <Link href="/dashboard/billing/settings">
            Factuurinstellingen
          </Link>
        </Button>
      </div>
    </div>
  );
}
