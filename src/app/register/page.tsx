"use client";

import * as React from "react";
import { Loader2, MailCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, ensureCsrfCookie, parseApiError } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

function RegisterForm() {
  const { toast } = useToast();

  const [name, setName] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [done, setDone] = React.useState(false);

  React.useEffect(() => {
    ensureCsrfCookie();
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (password !== passwordConfirm) {
      toast({
        variant: "destructive",
        title: "Wachtwoorden komen niet overeen",
      });
      return;
    }
    setLoading(true);
    try {
      await authApi.register(name, email, password, passwordConfirm);
      setDone(true);
    } catch (err: unknown) {
      toast({
        variant: "destructive",
        title: "Registratie mislukt",
        description: parseApiError(err, "Controleer de ingevulde gegevens."),
      });
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      {/* Ambient glow orbs */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      {/* Header */}
      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10 transition-all duration-300">
        <div className="max-w-7xl mx-auto flex justify-between items-center px-6 lg:px-8 h-16 w-full">
          <a href={process.env.NEXT_PUBLIC_WEBSITE_URL || "/"} className="flex items-center gap-3">
            <span className="material-symbols-outlined text-accent" style={{ fontVariationSettings: "'FILL' 1" }}>dns</span>
            <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
          </a>
        </div>
      </header>

      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              {done ? "Account aangemaakt" : "Maak een account aan"}
            </h1>
            <p className="text-muted-foreground">
              {done
                ? "Controleer je e-mail voor een bevestigingslink"
                : "Registreer je bij Bunk Hosting"}
            </p>
          </div>

          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {done ? (
              <div className="space-y-5 text-center">
                <div className="flex justify-center">
                  <MailCheck className="h-12 w-12 text-primary" />
                </div>
                <p className="text-sm text-muted-foreground">
                  Als je e-mailadres is goedgekeurd ontvang je een bevestigingslink. Klik op de link om je account te activeren.
                </p>
                <a href="/login">
                  <Button className="w-full py-5">Naar inloggen</Button>
                </a>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="space-y-5">
                <div className="space-y-2">
                  <Label htmlFor="name">Naam</Label>
                  <Input
                    id="name"
                    type="text"
                    placeholder="Jan de Vries"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    required
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
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
                </div>

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={loading || !name.trim() || !email.trim() || !password || !passwordConfirm}
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Account aanmaken
                </Button>

                <p className="text-center text-sm text-muted-foreground">
                  Al een account?{" "}
                  <a href="/login" className="text-primary underline-offset-4 hover:underline">
                    Inloggen
                  </a>
                </p>
              </form>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

export default function RegisterPage() {
  return (
    <React.Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center">
          <Loader2 className="h-8 w-8 animate-spin text-primary" />
        </div>
      }
    >
      <RegisterForm />
    </React.Suspense>
  );
}
