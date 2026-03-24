"use client";

import Link from "next/link";
import { Shield, Zap, Server, Globe } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@/components/ui/card";
import { Navbar } from "@/components/layout/navbar";
import { formatPrice } from "@/lib/utils";

const features = [
  {
    icon: Shield,
    title: "Betrouwbaar",
    description:
      "99,9% uptime garantie met redundante infrastructuur en automatische failover.",
  },
  {
    icon: Zap,
    title: "Razendsnel",
    description:
      "Krachtige processors en snelle netwerken zorgen voor optimale prestaties.",
  },
  {
    icon: Server,
    title: "NVMe SSD",
    description:
      "Alle servers draaien op ultrasnelle NVMe SSD opslag voor maximale I/O snelheid.",
  },
  {
    icon: Globe,
    title: "Nederlands Netwerk",
    description:
      "Gehost in Nederlandse datacenters met uitstekende connectiviteit.",
  },
];

const packages = [
  {
    name: "Starter",
    cpu: 1,
    ram: 1,
    disk: 20,
    bandwidth: 1,
    price: 3.99,
  },
  {
    name: "Basic",
    cpu: 2,
    ram: 2,
    disk: 40,
    bandwidth: 2,
    price: 7.99,
  },
  {
    name: "Pro",
    cpu: 4,
    ram: 8,
    disk: 80,
    bandwidth: 5,
    price: 14.99,
  },
  {
    name: "Business",
    cpu: 8,
    ram: 16,
    disk: 160,
    bandwidth: 10,
    price: 29.99,
  },
];

export default function HomePage() {
  return (
    <div className="min-h-screen flex flex-col">
      <Navbar />

      <main className="flex-1">
        {/* Hero */}
        <section className="py-20 md:py-32">
          <div className="container flex flex-col items-center text-center gap-6">
            <h1 className="text-4xl font-bold tracking-tight sm:text-5xl md:text-6xl">
              Krachtige{" "}
              <span className="text-primary">VPS Hosting</span>
            </h1>
            <p className="max-w-[600px] text-lg text-muted-foreground">
              Betrouwbare en snelle virtuele servers uit Nederland. Start vandaag
              nog met jouw eigen VPS met NVMe SSD opslag en een uitstekend
              netwerk.
            </p>
            <div className="flex flex-col sm:flex-row gap-4">
              <Button size="lg" asChild>
                <Link href="/products">Bekijk pakketten</Link>
              </Button>
              <Button size="lg" variant="outline" asChild>
                <Link href="/register">Aan de slag</Link>
              </Button>
            </div>
          </div>
        </section>

        {/* Features */}
        <section className="py-16 bg-muted/50">
          <div className="container">
            <h2 className="text-3xl font-bold text-center mb-12">
              Waarom Bunk Hosting?
            </h2>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
              {features.map((feature) => (
                <Card key={feature.title} className="text-center">
                  <CardHeader>
                    <div className="mx-auto mb-2 flex h-12 w-12 items-center justify-center rounded-lg bg-primary/10">
                      <feature.icon className="h-6 w-6 text-primary" />
                    </div>
                    <CardTitle className="text-xl">{feature.title}</CardTitle>
                  </CardHeader>
                  <CardContent>
                    <p className="text-sm text-muted-foreground">
                      {feature.description}
                    </p>
                  </CardContent>
                </Card>
              ))}
            </div>
          </div>
        </section>

        {/* Pricing Preview */}
        <section className="py-16">
          <div className="container">
            <h2 className="text-3xl font-bold text-center mb-4">
              Onze Pakketten
            </h2>
            <p className="text-center text-muted-foreground mb-12">
              Kies het pakket dat bij jou past. Altijd opschaalbaar.
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
              {packages.map((pkg) => (
                <Card key={pkg.name} className="flex flex-col">
                  <CardHeader>
                    <CardTitle>{pkg.name}</CardTitle>
                    <CardDescription>
                      <span className="text-3xl font-bold text-foreground">
                        {formatPrice(pkg.price)}
                      </span>
                      <span className="text-muted-foreground">/mnd</span>
                    </CardDescription>
                  </CardHeader>
                  <CardContent className="flex-1">
                    <ul className="space-y-2 text-sm">
                      <li>{pkg.cpu} vCPU</li>
                      <li>{pkg.ram} GB RAM</li>
                      <li>{pkg.disk} GB NVMe SSD</li>
                      <li>{pkg.bandwidth} TB bandbreedte</li>
                    </ul>
                  </CardContent>
                  <CardFooter>
                    <Button className="w-full" asChild>
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
