"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Check } from "lucide-react";
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
import { useToast } from "@/components/ui/use-toast";
import { packagesApi, vpsApi } from "@/lib/api";
import { cn, formatPrice } from "@/lib/utils";
import type { VpsPackage } from "@/lib/types";

export default function NewVpsPage() {
  const router = useRouter();
  const { toast } = useToast();

  const [packages, setPackages] = useState<VpsPackage[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);

  const [selectedPackageId, setSelectedPackageId] = useState<number | null>(null);
  const [label, setLabel] = useState("");

  useEffect(() => {
    async function fetchPackages() {
      try {
        const response = await packagesApi.list();
        const allowed = ["Starter", "Basic", "Pro"];
        setPackages(response.data.results.filter((p) => allowed.includes(p.name)));
      } catch {
        toast({
          title: "Fout",
          description: "Kon pakketten niet laden.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    fetchPackages();
  }, [toast]);

  const handleSubmit = async () => {
    if (!selectedPackageId) {
      toast({
        title: "Selecteer een pakket",
        description: "Kies een VPS pakket om verder te gaan.",
        variant: "destructive",
      });
      return;
    }

    setSubmitting(true);
    try {
      await vpsApi.create({
        package_id: selectedPackageId,
        os: "ubuntu-22.04",
        label: label || undefined,
      });
      toast({
        title: "Gelukt!",
        description: "VPS aanvraag ingediend!",
      });
      router.push("/dashboard/vps");
    } catch (error: unknown) {
      const message =
        error instanceof Error ? error.message : "Er is iets misgegaan.";
      toast({
        title: "Fout bij aanvragen",
        description: message,
        variant: "destructive",
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-4xl space-y-8">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Nieuwe VPS Aanvragen</h1>
        <p className="text-muted-foreground">
          Kies een pakket en geef je VPS optioneel een naam.
        </p>
      </div>

      {/* Pakket kiezen */}
      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Kies een pakket</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {packages.map((pkg) => (
            <Card
              key={pkg.id}
              className={cn(
                "cursor-pointer transition-all",
                selectedPackageId === pkg.id
                  ? "border-primary ring-2 ring-primary"
                  : "hover:border-primary/50"
              )}
              onClick={() => setSelectedPackageId(pkg.id)}
            >
              <CardHeader className="pb-3">
                <div className="flex items-center justify-between">
                  <CardTitle className="text-lg">{pkg.name}</CardTitle>
                  {selectedPackageId === pkg.id && (
                    <Check className="h-5 w-5 text-primary" />
                  )}
                </div>
                <CardDescription>{pkg.description}</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="space-y-1 text-sm">
                  <p>{pkg.cpu_cores} vCPU</p>
                  <p>{pkg.ram_gb} GB RAM</p>
                  <p>{pkg.disk_gb} GB NVMe opslag</p>
                  <p>{pkg.bandwidth_tb} TB bandbreedte</p>
                </div>
                <p className="mt-3 text-lg font-bold text-primary">
                  {formatPrice(pkg.price_monthly)}/maand
                </p>
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      {/* Naam */}
      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Naam (optioneel)</h2>
        <div className="max-w-sm space-y-2">
          <Label htmlFor="label">Naam voor je VPS</Label>
          <Input
            id="label"
            placeholder="Bijv. Webserver, Database, etc."
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
        </div>
      </div>

      {/* Submit */}
      <div className="flex gap-4">
        <Button onClick={handleSubmit} disabled={submitting}>
          {submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
          VPS Aanvragen
        </Button>
        <Button
          variant="outline"
          onClick={() => router.push("/dashboard/vps")}
          disabled={submitting}
        >
          Annuleren
        </Button>
      </div>
    </div>
  );
}
