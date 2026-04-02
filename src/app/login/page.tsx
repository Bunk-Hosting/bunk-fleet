"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Turnstile } from "@marsidev/react-turnstile";
import type { TurnstileInstance } from "@marsidev/react-turnstile";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, ensureCsrfCookie } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY || "";
const TURNSTILE_REQUIRED_AFTER = 2;

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { toast } = useToast();

  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [failedAttempts, setFailedAttempts] = React.useState(0);
  const [turnstileToken, setTurnstileToken] = React.useState("");
  const turnstileRef = React.useRef<TurnstileInstance>(null);

  const showTurnstile = failedAttempts >= TURNSTILE_REQUIRED_AFTER && !!TURNSTILE_SITE_KEY;

  React.useEffect(() => {
    ensureCsrfCookie();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (showTurnstile && !turnstileToken) {
      toast({
        variant: "destructive",
        title: "Verificatie vereist",
        description: "Los de human verificatie op voordat je inlogt.",
      });
      return;
    }

    setLoading(true);

    try {
      await authApi.login(email, password, showTurnstile ? turnstileToken : undefined);
      const next = searchParams.get("next") || "/dashboard";
      router.push(next);
    } catch (err: unknown) {
      const error = err as { response?: { data?: { detail?: string; turnstile_required?: boolean } } };
      const newFails = failedAttempts + 1;
      setFailedAttempts(newFails);

      // Reset Turnstile widget zodat de gebruiker opnieuw kan verifiëren
      if (turnstileRef.current) {
        turnstileRef.current.reset();
      }
      setTurnstileToken("");

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
      {/* Ambient glow orbs — exact match bunkhosting.nl */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      {/* Header — exact bunkhosting stijl */}
      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10 transition-all duration-300">
        <div className="max-w-7xl mx-auto flex justify-between items-center px-6 lg:px-8 h-16 w-full">
          <a href={process.env.NEXT_PUBLIC_WEBSITE_URL || "/"} className="flex items-center gap-3">
            <span className="material-symbols-outlined text-accent" style={{ fontVariationSettings: "'FILL' 1" }}>dns</span>
            <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
          </a>
          <p className="text-sm text-muted-foreground hidden sm:block">
            Nog geen account?{" "}
            <Link href="/register" className="text-accent hover:text-foreground transition-colors font-semibold">Registreren</Link>
          </p>
        </div>
      </header>

      {/* Form */}
      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
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

              {/* Turnstile — verschijnt na 2 mislukte pogingen */}
              {showTurnstile && (
                <div className="flex flex-col gap-1.5">
                  <p className="text-sm text-muted-foreground">
                    Bevestig dat je een mens bent om door te gaan.
                  </p>
                  <Turnstile
                    ref={turnstileRef}
                    siteKey={TURNSTILE_SITE_KEY}
                    onSuccess={(token) => setTurnstileToken(token)}
                    onError={() => setTurnstileToken("")}
                    onExpire={() => setTurnstileToken("")}
                  />
                </div>
              )}

              <Button
                type="submit"
                className="w-full py-5"
                disabled={loading || (showTurnstile && !turnstileToken)}
              >
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
