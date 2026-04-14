"use client";

import * as React from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Loader2, ArrowLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, ensureCsrfCookie } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

type Step = "email" | "otp";

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { toast } = useToast();

  const [step, setStep] = React.useState<Step>("email");
  const [email, setEmail] = React.useState("");
  const [code, setCode] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [secondsLeft, setSecondsLeft] = React.useState(0);

  React.useEffect(() => {
    ensureCsrfCookie();
  }, []);

  // Countdown timer — start wanneer step "otp" wordt
  React.useEffect(() => {
    if (step !== "otp") return;
    setSecondsLeft(600);
    const interval = setInterval(() => {
      setSecondsLeft((s) => {
        if (s <= 1) {
          clearInterval(interval);
          return 0;
        }
        return s - 1;
      });
    }, 1000);
    return () => clearInterval(interval);
  }, [step]);

  function formatTime(s: number) {
    const m = Math.floor(s / 60).toString().padStart(2, "0");
    const sec = (s % 60).toString().padStart(2, "0");
    return `${m}:${sec}`;
  }

  async function handleRequestOtp(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.requestOtp(email);
      setStep("otp");
    } catch {
      toast({
        variant: "destructive",
        title: "Er is een fout opgetreden. Probeer het opnieuw.",
      });
    } finally {
      setLoading(false);
    }
  }

  async function handleVerifyOtp(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.verifyOtp(email, code);
      const next = searchParams.get("next") || "/dashboard";
      router.push(next);
    } catch {
      toast({
        variant: "destructive",
        title: "Inloggen mislukt",
        description: "Ongeldige of verlopen code.",
      });
      setCode("");
    } finally {
      setLoading(false);
    }
  }

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
        </div>
      </header>

      {/* Form */}
      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          {/* Heading */}
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              {step === "email" ? "Welkom terug" : "Controleer je e-mail"}
            </h1>
            <p className="text-muted-foreground">
              {step === "email"
                ? "Log in op je Bunk Hosting account"
                : `We hebben een code gestuurd naar ${email}`}
            </p>
          </div>

          {/* Card */}
          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {step === "email" ? (
              <form onSubmit={handleRequestOtp} className="space-y-5">
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

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={loading || !email.trim()}
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Stuur inlogcode
                </Button>
              </form>
            ) : (
              <form onSubmit={handleVerifyOtp} className="space-y-5">
                <div className="space-y-2">
                  <Label htmlFor="otp">Inlogcode</Label>
                  <Input
                    id="otp"
                    type="text"
                    inputMode="numeric"
                    maxLength={6}
                    placeholder="123456"
                    value={code}
                    onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                    required
                    disabled={loading}
                    autoFocus
                    className="bg-background/60 border-border/60 focus:border-primary/60 text-center tracking-widest text-lg"
                  />
                  <p className="text-xs text-muted-foreground text-center">
                    {secondsLeft > 0
                      ? `Code geldig tot: ${formatTime(secondsLeft)}`
                      : "Code is verlopen. Ga terug en probeer opnieuw."}
                  </p>
                </div>

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={loading || code.length !== 6 || secondsLeft === 0}
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Inloggen
                </Button>

                <Button
                  type="button"
                  variant="ghost"
                  className="w-full"
                  onClick={() => {
                    setStep("email");
                    setCode("");
                  }}
                  disabled={loading}
                >
                  <ArrowLeft className="mr-2 h-4 w-4" />
                  Terug
                </Button>
              </form>
            )}
          </div>
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
