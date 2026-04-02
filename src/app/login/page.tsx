"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { toast } = useToast();

  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [loading, setLoading] = React.useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    try {
      await authApi.login(email, password);
      const next = searchParams.get("next") || "/dashboard";
      router.push(next);
    } catch (err: unknown) {
      const error = err as { response?: { data?: { detail?: string } } };
      toast({
        variant: "destructive",
        title: "Inloggen mislukt",
        description:
          error.response?.data?.detail ||
          "Controleer je e-mailadres en wachtwoord.",
      });
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      {/* Glow orbs — matches website */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden">
        <div className="absolute -top-40 -left-40 w-96 h-96 rounded-full bg-primary/10 blur-3xl" />
        <div className="absolute -bottom-40 -right-40 w-96 h-96 rounded-full bg-accent/8 blur-3xl" />
      </div>

      {/* Minimal nav */}
      <header className="relative z-10 flex items-center justify-between px-6 py-5 border-b border-border/40">
        <a
          href={process.env.NEXT_PUBLIC_WEBSITE_URL || "/"}
          className="flex items-center gap-2"
        >
          <span
            className="material-symbols-outlined text-accent"
            style={{ fontVariationSettings: "'FILL' 1" }}
          >
            dns
          </span>
          <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
            BUNK HOSTING
          </span>
        </a>
        <p className="text-sm text-muted-foreground hidden sm:block">
          Nog geen account?{" "}
          <Link href="/register" className="text-primary hover:text-accent transition-colors">
            Registreren
          </Link>
        </p>
      </header>

      {/* Form */}
      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4">
        <div className="w-full max-w-md">
          {/* Heading */}
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              Welkom terug
            </h1>
            <p className="text-muted-foreground">
              Log in op je Bunk Hosting account
            </p>
          </div>

          {/* Card */}
          <div className="card-gradient-border rounded-xl p-6 bg-card">
            <form onSubmit={handleSubmit} className="space-y-5">
              <div className="space-y-2">
                <Label htmlFor="email">E-mailadres</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="naam@voorbeeld.nl"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  disabled={loading}
                  className="bg-background/60 border-border/60 focus:border-primary/60"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="password">Wachtwoord</Label>
                <Input
                  id="password"
                  type="password"
                  placeholder="••••••••"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  disabled={loading}
                  className="bg-background/60 border-border/60 focus:border-primary/60"
                />
              </div>
              <Button type="submit" className="w-full py-5" disabled={loading}>
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Inloggen
              </Button>
            </form>
          </div>

          <p className="text-center text-sm text-muted-foreground mt-6 sm:hidden">
            Nog geen account?{" "}
            <Link href="/register" className="text-primary hover:text-accent transition-colors">
              Registreren
            </Link>
          </p>
        </div>
      </main>
    </div>
  );
}

export default function LoginPage() {
  return (
    <React.Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center">
          <Loader2 className="h-8 w-8 animate-spin text-primary" />
        </div>
      }
    >
      <LoginForm />
    </React.Suspense>
  );
}
