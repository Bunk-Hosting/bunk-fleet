"use client";

import * as React from "react";
import Link from "next/link";
import { useSearchParams, useRouter } from "next/navigation";
import { Loader2, CheckCircle, XCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, ensureCsrfCookie } from "@/lib/api";

function ResetPasswordContent() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const token = searchParams.get("token") ?? "";

  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [status, setStatus] = React.useState<"form" | "success" | "error">("form");
  const [errorMessage, setErrorMessage] = React.useState("");

  React.useEffect(() => {
    ensureCsrfCookie();
    if (!token) {
      setStatus("error");
      setErrorMessage("Geen resettoken gevonden in de link. Vraag een nieuwe resetlink aan.");
    }
  }, [token]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password !== passwordConfirm) {
      setErrorMessage("Wachtwoorden komen niet overeen.");
      setStatus("error");
      return;
    }
    setLoading(true);
    try {
      await authApi.confirmPasswordReset(token, password, passwordConfirm);
      setStatus("success");
      setTimeout(() => router.push("/login"), 3000);
    } catch (err: unknown) {
      const error = err as { response?: { data?: { detail?: string | string[] } } };
      const detail = error.response?.data?.detail;
      setErrorMessage(
        Array.isArray(detail) ? detail.join(" ") : (detail ?? "Er is een fout opgetreden.")
      );
      setStatus("error");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10">
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
            <h1 className="text-3xl font-display font-bold mb-2">Nieuw wachtwoord</h1>
            <p className="text-muted-foreground">Kies een sterk wachtwoord voor je account.</p>
          </div>

          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {status === "success" && (
              <div className="text-center py-4">
                <CheckCircle className="h-12 w-12 text-green-500 mx-auto mb-4" />
                <h2 className="text-lg font-semibold mb-2">Wachtwoord gewijzigd!</h2>
                <p className="text-sm text-muted-foreground">Je wordt doorgestuurd naar de inlogpagina…</p>
              </div>
            )}

            {status === "error" && (
              <div className="text-center py-4">
                <XCircle className="h-12 w-12 text-destructive mx-auto mb-4" />
                <h2 className="text-lg font-semibold mb-2">Mislukt</h2>
                <p className="text-sm text-muted-foreground mb-6">{errorMessage}</p>
                <Button asChild variant="outline" className="w-full">
                  <Link href="/forgot-password">Nieuwe resetlink aanvragen</Link>
                </Button>
              </div>
            )}

            {status === "form" && (
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="password">Nieuw wachtwoord</Label>
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
                <Button type="submit" className="w-full py-5" disabled={loading}>
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Wachtwoord opslaan
                </Button>
              </form>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

export default function ResetPasswordPage() {
  return (
    <React.Suspense fallback={null}>
      <ResetPasswordContent />
    </React.Suspense>
  );
}
