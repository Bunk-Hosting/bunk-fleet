"use client";

import { useEffect, useState } from "react";
import { Loader2, Save, Building2, Receipt, Percent } from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { adminBillingApi } from "@/lib/api";
import type { CompanySettings } from "@/lib/types";
import { useToast } from "@/components/ui/use-toast";

export default function AdminSettingsPage() {
  const { toast } = useToast();
  const [settings, setSettings] = useState<CompanySettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  // Form state
  const [form, setForm] = useState({
    company_name: "",
    address_line1: "",
    address_line2: "",
    postal_code: "",
    city: "",
    country: "",
    kvk_number: "",
    vat_number: "",
    vat_rate: "",
    yearly_discount_rate: "",
    support_email: "",
    invoice_prefix: "",
  });

  useEffect(() => {
    async function load() {
      try {
        const res = await adminBillingApi.company.get();
        const data = res.data;
        setSettings(data);
        setForm({
          company_name: data.company_name,
          address_line1: data.address_line1,
          address_line2: data.address_line2,
          postal_code: data.postal_code,
          city: data.city,
          country: data.country,
          kvk_number: data.kvk_number,
          vat_number: data.vat_number,
          vat_rate: (Number(data.vat_rate) * 100).toFixed(0),
          yearly_discount_rate: (Number(data.yearly_discount_rate) * 100).toFixed(0),
          support_email: data.support_email,
          invoice_prefix: data.invoice_prefix,
        });
      } catch {
        toast({
          title: "Fout",
          description: "Kon bedrijfsinstellingen niet laden.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [toast]);

  const handleChange = (field: keyof typeof form) => (
    e: React.ChangeEvent<HTMLInputElement>
  ) => {
    setForm((prev) => ({ ...prev, [field]: e.target.value }));
  };

  const handleSave = async () => {
    const vatRateNum = Number(form.vat_rate) / 100;
    const discountNum = Number(form.yearly_discount_rate) / 100;

    if (isNaN(vatRateNum) || vatRateNum < 0 || vatRateNum > 1) {
      toast({ title: "Ongeldig BTW-tarief", description: "Voer een percentage in tussen 0 en 100.", variant: "destructive" });
      return;
    }
    if (isNaN(discountNum) || discountNum < 0 || discountNum > 0.10) {
      toast({ title: "Ongeldige korting", description: "Jaarlijkse korting mag maximaal 10% zijn.", variant: "destructive" });
      return;
    }

    setSaving(true);
    try {
      const res = await adminBillingApi.company.update({
        ...form,
        vat_rate: vatRateNum.toFixed(4) as unknown as string,
        yearly_discount_rate: discountNum.toFixed(4) as unknown as string,
      });
      setSettings(res.data);
      toast({
        title: "Opgeslagen",
        description: "Bedrijfsinstellingen zijn bijgewerkt.",
      });
    } catch (err: unknown) {
      const error = err as { response?: { data?: Record<string, string[]> } };
      const firstError = error.response?.data
        ? Object.values(error.response.data).flat()[0]
        : "Er is een fout opgetreden.";
      toast({
        title: "Opslaan mislukt",
        description: firstError,
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-8 max-w-2xl">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Instellingen</h1>
        <p className="text-muted-foreground">
          Bedrijfsgegevens die op facturen worden weergegeven.
        </p>
      </div>

      {/* Bedrijfsgegevens */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Building2 className="h-5 w-5 text-primary" />
            <CardTitle>Bedrijfsgegevens</CardTitle>
          </div>
          <CardDescription>
            Deze gegevens verschijnen op alle facturen die naar klanten worden verstuurd.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="company_name">Bedrijfsnaam</Label>
            <Input
              id="company_name"
              value={form.company_name}
              onChange={handleChange("company_name")}
              placeholder="Bunk Hosting"
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="address_line1">Adresregel 1</Label>
            <Input
              id="address_line1"
              value={form.address_line1}
              onChange={handleChange("address_line1")}
              placeholder="Straatnaam 12"
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="address_line2">Adresregel 2 (optioneel)</Label>
            <Input
              id="address_line2"
              value={form.address_line2}
              onChange={handleChange("address_line2")}
              placeholder="Toevoeging, postbus, etc."
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="postal_code">Postcode</Label>
              <Input
                id="postal_code"
                value={form.postal_code}
                onChange={handleChange("postal_code")}
                placeholder="1234 AB"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="city">Stad</Label>
              <Input
                id="city"
                value={form.city}
                onChange={handleChange("city")}
                placeholder="Amsterdam"
              />
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor="country">Land</Label>
            <Input
              id="country"
              value={form.country}
              onChange={handleChange("country")}
              placeholder="Nederland"
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="support_email">Support e-mailadres</Label>
            <Input
              id="support_email"
              type="email"
              value={form.support_email}
              onChange={handleChange("support_email")}
              placeholder="support@bunkhosting.nl"
            />
          </div>
        </CardContent>
      </Card>

      {/* Fiscale gegevens */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Receipt className="h-5 w-5 text-primary" />
            <CardTitle>Fiscale gegevens</CardTitle>
          </div>
          <CardDescription>
            BTW-nummer en KVK-nummer worden op facturen vermeld.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="vat_number">BTW-nummer</Label>
            <Input
              id="vat_number"
              value={form.vat_number}
              onChange={handleChange("vat_number")}
              placeholder="NL123456789B01"
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="kvk_number">KVK-nummer</Label>
            <Input
              id="kvk_number"
              value={form.kvk_number}
              onChange={handleChange("kvk_number")}
              placeholder="12345678"
            />
          </div>
        </CardContent>
      </Card>

      {/* Factuurinstellingen */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Percent className="h-5 w-5 text-primary" />
            <CardTitle>Facturatie-instellingen</CardTitle>
          </div>
          <CardDescription>
            Tarieven en nummering voor facturen.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="vat_rate">BTW-tarief (%)</Label>
              <div className="relative">
                <Input
                  id="vat_rate"
                  type="number"
                  min="0"
                  max="100"
                  step="1"
                  value={form.vat_rate}
                  onChange={handleChange("vat_rate")}
                  className="pr-8"
                />
                <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground">
                  %
                </span>
              </div>
              <p className="text-xs text-muted-foreground">Standaard: 21%</p>
            </div>
            <div className="space-y-2">
              <Label htmlFor="yearly_discount_rate">Jaarkorting (%)</Label>
              <div className="relative">
                <Input
                  id="yearly_discount_rate"
                  type="number"
                  min="0"
                  max="10"
                  step="1"
                  value={form.yearly_discount_rate}
                  onChange={handleChange("yearly_discount_rate")}
                  className="pr-8"
                />
                <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground">
                  %
                </span>
              </div>
              <p className="text-xs text-muted-foreground">Maximum: 10% — huidig: {settings?.yearly_discount_percent}</p>
            </div>
          </div>

          <Separator />

          <div className="space-y-2">
            <Label htmlFor="invoice_prefix">Factuurprefix</Label>
            <Input
              id="invoice_prefix"
              value={form.invoice_prefix}
              onChange={handleChange("invoice_prefix")}
              placeholder="BUNK"
              className="max-w-32"
            />
            <p className="text-xs text-muted-foreground">
              Factuurnummers worden opgebouwd als: {form.invoice_prefix || "BUNK"}-{new Date().getFullYear()}-0001
            </p>
          </div>
        </CardContent>
      </Card>

      <Button onClick={handleSave} disabled={saving} size="lg" className="gap-2">
        {saving ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <Save className="h-4 w-4" />
        )}
        Instellingen opslaan
      </Button>
    </div>
  );
}
