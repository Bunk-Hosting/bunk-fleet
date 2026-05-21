"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Download, CreditCard, Loader2, CheckCircle2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { billingApi } from "@/lib/api";
import type { Invoice } from "@/lib/types";
import { useToast } from "@/components/ui/use-toast";
import { formatEuro, formatDateLong as formatDate } from "@/lib/utils";

const statusConfig: Record<string, { label: string; variant: "default" | "secondary" | "destructive" | "outline" }> = {
  open: { label: "Openstaand", variant: "destructive" },
  paid: { label: "Betaald", variant: "default" },
  draft: { label: "Concept", variant: "secondary" },
  void: { label: "Vervallen", variant: "outline" },
};


export default function InvoiceDetailPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const { toast } = useToast();
  const [invoice, setInvoice] = useState<Invoice | null>(null);
  const [loading, setLoading] = useState(true);
  const [paying, setPaying] = useState(false);

  useEffect(() => {
    async function load() {
      try {
        const res = await billingApi.invoices.get(Number(id));
        setInvoice(res.data);
      } catch {
        toast({
          title: "Niet gevonden",
          description: "Deze factuur bestaat niet of je hebt er geen toegang toe.",
          variant: "destructive",
        });
        router.push("/dashboard/billing/invoices");
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, router, toast]);

  const handlePay = async () => {
    if (!invoice) return;
    setPaying(true);
    try {
      await billingApi.invoices.pay(invoice.id);
      const res = await billingApi.invoices.get(invoice.id);
      setInvoice(res.data);
      toast({
        title: "Betaling geslaagd",
        description: `Factuur ${invoice.invoice_number} is gemarkeerd als betaald.`,
      });
    } catch {
      toast({
        title: "Betaling mislukt",
        description: "Er is een fout opgetreden. Probeer het opnieuw.",
        variant: "destructive",
      });
    } finally {
      setPaying(false);
    }
  };

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!invoice) return null;

  const cfg = statusConfig[invoice.status] ?? { label: invoice.status, variant: "secondary" as const };
  const vatPct = invoice.vat_rate ? Math.round(Number(invoice.vat_rate) * 100) : 21;

  return (
    <div className="space-y-6 max-w-3xl mx-auto">
      {/* Header */}
      <div className="flex items-center gap-4">
        <Button variant="ghost" size="icon" onClick={() => router.back()}>
          <ArrowLeft className="h-4 w-4" />
        </Button>
        <div className="flex-1">
          <h1 className="text-2xl font-bold tracking-tight">{invoice.invoice_number}</h1>
          <p className="text-muted-foreground">
            Periode {formatDate(invoice.period_start)} t/m {formatDate(invoice.period_end)}
          </p>
        </div>
        <Badge variant={cfg.variant} className="text-sm px-3 py-1">
          {cfg.label}
        </Badge>
      </div>

      {/* Factuurdetail kaart */}
      <Card>
        <CardHeader>
          <CardTitle>Factuurdetails</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          {/* Van / Aan */}
          <div className="grid grid-cols-2 gap-6 text-sm">
            <div>
              <p className="font-semibold text-muted-foreground mb-1">Van</p>
              <p className="font-semibold">{invoice.company_name}</p>
              {invoice.company_address && (
                <p className="text-muted-foreground whitespace-pre-line">
                  {invoice.company_address}
                </p>
              )}
              {invoice.company_vat_number && (
                <p className="text-muted-foreground">BTW: {invoice.company_vat_number}</p>
              )}
              {invoice.company_kvk_number && (
                <p className="text-muted-foreground">KVK: {invoice.company_kvk_number}</p>
              )}
            </div>
            <div>
              <p className="font-semibold text-muted-foreground mb-1">Factuurgegevens</p>
              <div className="space-y-1 text-muted-foreground">
                <p><span className="text-foreground font-medium">Factuurdatum:</span>{" "}{formatDate(invoice.finalized_at ?? invoice.created_at)}</p>
                <p><span className="text-foreground font-medium">Vervaldatum:</span>{" "}{formatDate(invoice.due_date)}</p>
                {invoice.paid_at && (
                  <p><span className="text-foreground font-medium">Betaald op:</span>{" "}{formatDate(invoice.paid_at)}</p>
                )}
              </div>
            </div>
          </div>

          <Separator />

          {/* Regeloverzicht */}
          <div>
            <p className="font-semibold mb-3">Factuurregels</p>
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b text-muted-foreground text-xs uppercase tracking-wider">
                  <th className="pb-2 text-left font-medium">Omschrijving</th>
                  <th className="pb-2 text-right font-medium">Aantal</th>
                  <th className="pb-2 text-right font-medium">Stukprijs</th>
                  <th className="pb-2 text-right font-medium">Totaal</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {(invoice.lines ?? []).map((line) => {
                  const qty = Number(line.quantity);
                  const qtyStr = qty === 1 ? "1" : qty.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
                  return (
                    <tr key={line.id}>
                      <td className="py-3">{line.description}</td>
                      <td className="py-3 text-right text-muted-foreground">{qtyStr}</td>
                      <td className="py-3 text-right">{formatEuro(line.unit_price)}</td>
                      <td className="py-3 text-right font-medium">{formatEuro(line.line_total)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <Separator />

          {/* Totalen */}
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Subtotaal</span>
              <span>{formatEuro(invoice.subtotal)}</span>
            </div>
            {Number(invoice.discount_amount ?? 0) > 0 && (
              <div className="flex justify-between text-green-600">
                <span>Korting</span>
                <span>- {formatEuro(invoice.discount_amount ?? 0)}</span>
              </div>
            )}
            <div className="flex justify-between">
              <span className="text-muted-foreground">BTW ({vatPct}%)</span>
              <span>{formatEuro(invoice.vat_amount)}</span>
            </div>
            <Separator />
            <div className="flex justify-between text-base font-bold">
              <span>Te betalen</span>
              <span>{formatEuro(invoice.total)}</span>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Betaalgeschiedenis */}
      {(invoice.payments ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Betaalgeschiedenis</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {(invoice.payments ?? []).map((payment) => (
                <div
                  key={payment.id}
                  className="flex items-center justify-between text-sm rounded-lg border px-4 py-3"
                >
                  <div className="flex items-center gap-3">
                    <CheckCircle2 className="h-4 w-4 text-green-500" />
                    <div>
                      <p className="font-medium">{formatEuro(payment.amount)}</p>
                      <p className="text-xs text-muted-foreground">
                        {new Date(payment.attempted_at).toLocaleString("nl-NL")}
                      </p>
                    </div>
                  </div>
                  <Badge variant={payment.status === "succeeded" ? "default" : "destructive"}>
                    {payment.status === "succeeded" ? "Geslaagd" : payment.status}
                  </Badge>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Acties */}
      <div className="flex gap-3">
        {invoice.status === "open" && (
          <Button onClick={handlePay} disabled={paying} className="gap-2">
            {paying ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <CreditCard className="h-4 w-4" />
            )}
            Betaal {formatEuro(invoice.total)}
          </Button>
        )}
        <a
          href={billingApi.invoices.downloadUrl(invoice.id)}
          target="_blank"
          rel="noopener noreferrer"
        >
          <Button variant="outline" className="gap-2">
            <Download className="h-4 w-4" />
            Download PDF
          </Button>
        </a>
      </div>
    </div>
  );
}
