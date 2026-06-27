"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Download, Eye, Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { billingApi } from "@/lib/api";
import type { Invoice } from "@/lib/types";
import { useToast } from "@/components/ui/use-toast";
import { formatEuro, formatDate } from "@/lib/utils";

const STATUS_OPTIONS = [
  { value: "all", label: "Alle statussen" },
  { value: "open", label: "Openstaand" },
  { value: "paid", label: "Betaald" },
  { value: "void", label: "Vervallen" },
];

const statusConfig: Record<string, { label: string; variant: "default" | "secondary" | "destructive" | "outline" }> = {
  open: { label: "Openstaand", variant: "destructive" },
  paid: { label: "Betaald", variant: "default" },
  draft: { label: "Concept", variant: "secondary" },
  void: { label: "Vervallen", variant: "outline" },
};


export default function InvoiceListPage() {
  const { toast } = useToast();
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  useEffect(() => {
    async function load() {
      setLoading(true);
      try {
        const params = statusFilter !== "all" ? { status: statusFilter } : undefined;
        const res = await billingApi.invoices.list(params);
        setInvoices(res.data.results);
      } catch {
        toast({
          title: "Fout",
          description: "Kon facturen niet laden.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [statusFilter, toast]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Facturen</h1>
          <p className="text-muted-foreground">Overzicht van al je facturen.</p>
        </div>
        <Select value={statusFilter} onValueChange={setStatusFilter}>
          <SelectTrigger className="w-48">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {STATUS_OPTIONS.map((opt) => (
              <SelectItem key={opt.value} value={opt.value}>
                {opt.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>
            {invoices.length} {invoices.length === 1 ? "factuur" : "facturen"}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading ? (
            <div className="flex justify-center py-12">
              <Loader2 className="h-6 w-6 animate-spin text-primary" />
            </div>
          ) : invoices.length === 0 ? (
            <p className="text-sm text-muted-foreground py-10 text-center">
              Geen facturen gevonden.
            </p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-muted-foreground text-xs uppercase tracking-wider">
                    <th className="pb-3 text-left font-medium">Factuurnummer</th>
                    <th className="pb-3 text-left font-medium">Periode</th>
                    <th className="pb-3 text-left font-medium">Vervaldatum</th>
                    <th className="pb-3 text-right font-medium">Bedrag</th>
                    <th className="pb-3 text-center font-medium">Status</th>
                    <th className="pb-3 text-right font-medium">Acties</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {invoices.map((invoice) => {
                    const cfg = statusConfig[invoice.status] ?? { label: invoice.status, variant: "secondary" as const };
                    return (
                      <tr key={invoice.id} className="hover:bg-muted/30 transition-colors">
                        <td className="py-3 font-mono text-xs">{invoice.invoice_number}</td>
                        <td className="py-3 text-muted-foreground">
                          {formatDate(invoice.period_start)} – {formatDate(invoice.period_end)}
                        </td>
                        <td className="py-3 text-muted-foreground">
                          {formatDate(invoice.due_date)}
                        </td>
                        <td className="py-3 text-right font-semibold">
                          {formatEuro(invoice.total)}
                        </td>
                        <td className="py-3 text-center">
                          <Badge variant={cfg.variant}>{cfg.label}</Badge>
                        </td>
                        <td className="py-3">
                          <div className="flex items-center justify-end gap-2">
                            <Button variant="ghost" size="icon" asChild title="Bekijken">
                              <Link href={`/dashboard/billing/invoices/${invoice.id}`}>
                                <Eye className="h-4 w-4" />
                              </Link>
                            </Button>
                            <a
                              href={billingApi.invoices.downloadUrl(invoice.id)}
                              target="_blank"
                              rel="noopener noreferrer"
                              title="Download PDF"
                            >
                              <Button variant="ghost" size="icon">
                                <Download className="h-4 w-4" />
                              </Button>
                            </a>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
