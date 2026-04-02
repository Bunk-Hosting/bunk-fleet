"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Turnstile } from "@marsidev/react-turnstile";
import type { TurnstileInstance } from "@marsidev/react-turnstile";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, ensureCsrfCookie } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY || "";

export default function RegisterPage() {
  const router = useRouter();
  const { toast } = useToast();

  const [name, setName] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [errors, setErrors] = React.useState<Record<string, string[]>>({});
  const [inviteCode, setInviteCode] = React.useState("");
  const [turnstileToken, setTurnstileToken] = React.useState("");
  const turnstileRef = React.useRef<TurnstileInstance>(null);

  const turnstileEnabled = !!TURNSTILE_SITE_KEY;

  React.useEffect(() => {
    ensureCsrfCookie();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrors({});

    if (password !== passwordConfirm) {
      setErrors({ password_confirm: ["Wachtwoorden komen niet overeen."] });
      return;
    }

    if (turnstileEnabled && !turnstileToken) {
      toast({
        variant: "destructive",
        title: "Verificatie vereist",
        description: "Los de human verificatie op om door te gaan.",
      });
      return;
    }

    setLoading(true);

    try {
      await authApi.register({
        name,
        email,
        password,
        password_confirm: passwordConfirm,
        invite_code: inviteCode,
        ...(turnstileEnabled && { turnstile_token: turnstileToken }),
      });
      router.push("/dashboard");
    } catch (err: unknown) {
      const error = err as {
        response?: { data?: Record<string, string[] | string> };
      };

      // Reset Turnstile widget bij een fout
      if (turnstileRef.current) {
        turnstileRef.current.reset();
      }
      setTurnstileToken("");

      if (error.response?.data) {
        const data = error.response.data;
        const fieldErrors: Record<string, string[]> = {};
        let generalMessage = "";

        for (const [key, value] of Object.entries(data)) {
          if (key === "detail" && typeof value === "string") {
            generalMessage = value;
          } else if (Array.isArray(value)) {
            fieldErrors[key] = value;
          } else if (typeof value === "string") {
            fieldErrors[key] = [value];
          }
        }

        if (Object.keys(fieldErrors).length > 0) {
          setErrors(fieldErrors);
        } else {
          toast({
            variant: "destructive",
            title: "Registratie mislukt",
            description: generalMessage || "Er is een fout opgetreden.",
          });
        }
      } else {
        toast({
          variant: "destructive",
          title: "Registratie mislukt",
          description: "Er is een onverwachte fout opgetreden.",
        });
      }
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
            Al een account?{" "}
            <Link href="/login" className="text-accent hover:text-foreground transition-colors font-semibold">Inloggen</Link>
          </p>
        </div>
      </header>

      {/* Form */}
      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          {/* Heading */}
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              Account aanmaken
            </h1>
            <p className="text-muted-foreground">
              Start vandaag met Bunk Hosting
            </p>
          </div>

          {/* Card */}
          <div className="card-gradient-border rounded-xl p-6 bg-card">
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="name">Naam</Label>
                <Input
                  id="name"
                  type="text"
                  placeholder="Jan Jansen"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  required
                  disabled={loading}
                  className="bg-background/60 border-border/60 focus:border-primary/60"
                />
                {errors.name && (
                  <p className="text-sm text-destructive">{errors.name[0]}</p>
                )}
              </div>
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
                {errors.email && (
                  <p className="text-sm text-destructive">{errors.email[0]}</p>
                )}
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
                {errors.password && (
                  <p className="text-sm text-destructive">{errors.password[0]}</p>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="password_confirm">Wachtwoord bevestigen</Label>
                <Input
                  id="password_confirm"
                  type="password"
                  placeholder="••••••••"
                  value={passwordConfirm}
                  onChange={(e) => setPasswordConfirm(e.target.value)}
                  required
                  disabled={loading}
                  className="bg-background/60 border-border/60 focus:border-primary/60"
                />
                {errors.password_confirm && (
                  <p className="text-sm text-destructive">{errors.password_confirm[0]}</p>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="invite_code">Uitnodigingscode</Label>
                <Input
                  id="invite_code"
                  type="text"
                  placeholder="Voer je uitnodigingscode in"
                  value={inviteCode}
                  onChange={(e) => setInviteCode(e.target.value)}
                  required
                  disabled={loading}
                  className="bg-background/60 border-border/60 focus:border-primary/60 font-mono tracking-wider"
                />
                {errors.invite_code && (
                  <p className="text-sm text-destructive">{errors.invite_code[0]}</p>
                )}
              </div>

              {/* Turnstile — altijd zichtbaar als sitekey ingesteld is */}
              {turnstileEnabled && (
                <div className="pt-1">
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
                className="w-full py-5 mt-2"
                disabled={loading || (turnstileEnabled && !turnstileToken)}
              >
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Account aanmaken
              </Button>
            </form>
          </div>

          <p className="text-center text-sm text-muted-foreground mt-6 sm:hidden">
            Al een account?{" "}
            <Link href="/login" className="text-primary hover:text-accent transition-colors">
              Inloggen
            </Link>
          </p>
        </div>
      </main>
    </div>
  );
}
