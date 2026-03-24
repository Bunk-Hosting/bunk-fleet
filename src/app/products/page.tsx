"use client";

import Link from "next/link";
import { Cpu, MemoryStick, HardDrive, ArrowRightLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Navbar } from "@/components/layout/navbar";
import { formatPrice } from "@/lib/utils";

const packages = [
  {
    name: "Starter",
    cpu: 1,
    ram: 1,
    disk: 20,
    bandwidth: 1,
    price: 3.99,
    popular: false,
  },
  {
    name: "Basic",
    cpu: 2,
    ram: 2,
    disk: 40,
    bandwidth: 2,
    price: 7.99,
    popular: false,
  },
  {
    name: "Pro",
    cpu: 4,
    ram: 8,
    disk: 80,
    bandwidth: 5,
    price: 14.99,
    popular: true,
  },
  {
    name: "Business",
    cpu: 8,
    ram: 16,
    disk: 160,
    bandwidth: 10,
    price: 29.99,
    popular: false,
  },
];

export default function ProductsPage() {
  return (
    <div className="min-h-screen flex flex-col">
      <Navbar />

      <main className="flex-1">
        <section className="py-16 md:py-24">
          <div className="container">
            <div className="text-center mb-12">
              <h1 className="text-4xl font-bold tracking-tight mb-4">
                Onze VPS Pakketten
              </h1>
              <p className="text-lg text-muted-foreground max-w-[600px] mx-auto">
                Kies het VPS pakket dat het beste bij jouw behoeften past.
                Alle pakketten bevatten NVMe SSD opslag en zijn direct
                beschikbaar.
              </p>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
              {packages.map((pkg) => (
                <Card
                  key={pkg.name}
                  className={`flex flex-col relative ${
                    pkg.popular ? "border-primary shadow-md" : ""
                  }`}
                >
                  {pkg.popular && (
                    <Badge className="absolute -top-3 left-1/2 -translate-x-1/2">
                      Populair
                    </Badge>
                  )}
                  <CardHeader className="text-center">
                    <CardTitle className="text-2xl">{pkg.name}</CardTitle>
                    <CardDescription>
                      <span className="text-4xl font-bold text-foreground">
                        {formatPrice(pkg.price)}
                      </span>
                      <span className="text-muted-foreground">/mnd</span>
                    </CardDescription>
                  </CardHeader>
                  <CardContent className="flex-1">
                    <ul className="space-y-4">
                      <li className="flex items-center gap-3">
                        <Cpu className="h-4 w-4 text-muted-foreground shrink-0" />
                        <span className="text-sm">
                          <strong>{pkg.cpu}</strong> vCPU
                        </span>
                      </li>
                      <li className="flex items-center gap-3">
                        <MemoryStick className="h-4 w-4 text-muted-foreground shrink-0" />
                        <span className="text-sm">
                          <strong>{pkg.ram} GB</strong> RAM
                        </span>
                      </li>
                      <li className="flex items-center gap-3">
                        <HardDrive className="h-4 w-4 text-muted-foreground shrink-0" />
                        <span className="text-sm">
                          <strong>{pkg.disk} GB</strong> NVMe SSD opslag
                        </span>
                      </li>
                      <li className="flex items-center gap-3">
                        <ArrowRightLeft className="h-4 w-4 text-muted-foreground shrink-0" />
                        <span className="text-sm">
                          <strong>{pkg.bandwidth} TB</strong> bandbreedte
                        </span>
                      </li>
                    </ul>
                  </CardContent>
                  <CardFooter>
                    <Button
                      className="w-full"
                      variant={pkg.popular ? "default" : "outline"}
                      asChild
                    >
                      <Link href="/register">Bestellen</Link>
                    </Button>
                  </CardFooter>
                </Card>
              ))}
            </div>
          </div>
        </section>
      </main>

      {/* Footer */}
      <footer className="border-t py-8">
        <div className="container text-center text-sm text-muted-foreground">
          &copy; 2026 Bunk Hosting. Alle rechten voorbehouden.
        </div>
      </footer>
    </div>
  );
}
