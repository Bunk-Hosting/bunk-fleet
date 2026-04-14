"use client";

import { useEffect, useState } from "react";
import { Loader2, Save } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { billingApi } from "@/lib/api";
import type { BillingSettings } from "@/lib/types";
import { useToast } from "@/components/ui/use-toast";

export default function BillingSettingsPage() {
  const { toast } = useToast();
  const [settings, setSettings] = useState<BillingSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [billingCycle, setBillingCycle] = useState<"monthly" | "yearly">("monthly");
  const [billingEmail, setBillingEmail] = useState("");

  useEffect(() => {
    async function load() {
      try {
        const res = await billingApi.settings.get();
        setSettings(res.data);
        setBillingCycle(res.data.billing_cycle);
        setBillingEmail(res.data.billing_email);
      } catch {
        toast({
          title: "Fout",
          description: "Kon factuurinstellingen niet laden.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [toast]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const res = await billingApi.settings.update({
        billing_cycle: billingCycle,
        billing_email: billingEmail,
      });
      setSettings(res.data);
      toast({
        title: "Opgeslagen",
        description: "Factuurinstellingen zijn bijgewerkt.",
      });
    } catch {
      toast({
        title: "Fout",
        description: "Kon instellingen niet opslaan.",
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
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Factuurinstellingen</h1>
        <p className="text-muted-foreground">
          Stel je facturatiefrequentie en factuur-e-mailadres in.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Facturatiefrequentie</CardTitle>
          <CardDescription>
            Kies of je maandelijks of jaarlijks gefactureerd wil worden.
            Bij jaarlijkse facturatie ontvang je 10% korting.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="space-y-2">
            <Label htmlFor="billing-cycle">Facturatiecyclus</Label>
            <Select
              value={billingCycle}
              onValueChange={(val) => setBillingCycle(val as "monthly" | "yearly")}
            >
              <SelectTrigger id="billing-cycle" className="w-64">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="monthly">Maandelijks</SelectItem>
                <SelectItem value="yearly">Jaarlijks (10% korting)</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="billing-email">Factuur-e-mailadres</Label>
            <Input
              id="billing-email"
              type="email"
              placeholder="facturen@bedrijf.nl (leeg = account e-mail)"
              value={billingEmail}
              onChange={(e) => setBillingEmail(e.target.value)}
              className="max-w-sm"
            />
            <p className="text-xs text-muted-foreground">
              Laat leeg om facturen naar je account e-mailadres te sturen.
            </p>
          </div>

          <Button onClick={handleSave} disabled={saving} className="gap-2">
            {saving ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <Save className="h-4 w-4" />
            )}
            Opslaan
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
