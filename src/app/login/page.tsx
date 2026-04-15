"use client";

import * as React from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Loader2, ArrowLeft, MailCheck } from "lucide-react";
import { Turnstile } from "@marsidev/react-turnstile";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import axios from "axios";
import { authApi, ensureCsrfCookie, parseApiError } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

type Step = "credentials" | "otp" | "verify_required";

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { toast } = useToast();

  const [step, setStep] = React.useState<Step>("credentials");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [code, setCode] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [secondsLeft, setSecondsLeft] = React.useState(0);
  const [resendCooldown, setResendCooldown] = React.useState(0);
  const [turnstileRequired, setTurnstileRequired] = React.useState(false);
  const [turnstileToken, setTurnstileToken] = React.useState<string | null>(null);

  const turnstileSiteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY;

  React.useEffect(() => {
    ensureCsrfCookie();
  }, []);

  // 15-minuten countdown start zodra OTP-stap actief wordt
  React.useEffect(() => {
    if (step !== "otp") return;
    setSecondsLeft(900);
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

  // Cooldown-timer voor "Nieuwe code aanvragen"
  React.useEffect(() => {
    if (resendCooldown <= 0) return;
    const timer = setTimeout(() => setResendCooldown((c) => c - 1), 1000);
    return () => clearTimeout(timer);
  }, [resendCooldown]);

  function formatTime(s: number) {
    const m = Math.floor(s / 60).toString().padStart(2, "0");
    const sec = (s % 60).toString().padStart(2, "0");
    return `${m}:${sec}`;
  }

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      const res = await authApi.login(email, password, turnstileToken || undefined);
      if (res.data.otp_required) {
        setStep("otp");
      } else if (res.data.verification_required) {
        setStep("verify_required");
      } else {
        const next = searchParams.get("next") || "/dashboard";
        router.push(next);
      }
    } catch (err: unknown) {
      if (axios.isAxiosError(err)) {
        const data = err.response?.data as {
          verification_required?: boolean;
          turnstile_required?: boolean;
        } | undefined;
        if (data?.verification_required) {
          setStep("verify_required");
          return;
        }
        if (data?.turnstile_required) {
          setTurnstileRequired(true);
          setTurnstileToken(null);
        }
      }
      toast({
        variant: "destructive",
        title: "Inloggen mislukt",
        description: parseApiError(err, "Ongeldig e-mailadres of wachtwoord."),
      });
    } finally {
      setLoading(false);
    }
  }

  async function handleResend() {
    setLoading(true);
    try {
      await authApi.login(email, password);
      setCode("");
      setSecondsLeft(900);
      setResendCooldown(60);
      toast({
        title: "Nieuwe code verstuurd",
        description: "Check je e-mail voor de nieuwe inlogcode.",
      });
    } catch {
      toast({
        variant: "destructive",
        title: "Mislukt",
        description: "Kon geen nieuwe code versturen. Probeer opnieuw in te loggen.",
      });
    } finally {
      setLoading(false);
    }
  }

  async function handleOtp(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.loginOtp(email, code);
      setCode(""); // Leegmaken zodat knop disabled blijft tijdens navigatie
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

      {/* Form */}
      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          {/* Heading */}
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              {step === "credentials" && "Welkom terug"}
              {step === "otp" && "Controleer je e-mail"}
              {step === "verify_required" && "Bevestig je e-mailadres"}
            </h1>
            <p className="text-muted-foreground">
              {step === "credentials" && "Log in op je Bunk Hosting account"}
              {step === "otp" && `We hebben een code gestuurd naar ${email}`}
              {step === "verify_required" && `Er is een bevestigingslink verstuurd naar ${email}`}
            </p>
          </div>

          {/* Card */}
          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {step === "credentials" && (
              <form onSubmit={handleLogin} className="space-y-5">
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

                {turnstileRequired && (
                  <div className="space-y-2">
                    <Label>Bevestig dat je een mens bent</Label>
                    {turnstileSiteKey ? (
                      <Turnstile
                        siteKey={turnstileSiteKey}
                        onSuccess={(token) => setTurnstileToken(token)}
                        onExpire={() => setTurnstileToken(null)}
                        onError={() => setTurnstileToken(null)}
                      />
                    ) : (
                      <p className="text-sm text-destructive">
                        CAPTCHA configuratie ontbreekt. Zet NEXT_PUBLIC_TURNSTILE_SITE_KEY.
                      </p>
                    )}
                  </div>
                )}

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={loading || !email.trim() || !password || (turnstileRequired && !turnstileToken)}
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Inloggen
                </Button>

                <p className="text-center text-sm text-muted-foreground">
                  Nog geen account?{" "}
                  <a href="/register" className="text-primary underline-offset-4 hover:underline">
                    Registreren
                  </a>
                </p>
              </form>
            )}

            {step === "otp" && (
              <form onSubmit={handleOtp} className="space-y-5">
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
                      ? `Code geldig nog: ${formatTime(secondsLeft)}`
                      : "Code is verlopen. Ga terug en log opnieuw in."}
                  </p>
                </div>

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={loading || code.length !== 6 || secondsLeft === 0}
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Bevestig code
                </Button>

                <Button
                  type="button"
                  variant="ghost"
                  className="w-full"
                  onClick={() => {
                    setStep("credentials");
                    setCode("");
                  }}
                  disabled={loading}
                >
                  <ArrowLeft className="mr-2 h-4 w-4" />
                  Terug
                </Button>

                <p className="text-center text-sm text-muted-foreground">
                  Geen code ontvangen?{" "}
                  <button
                    type="button"
                    onClick={handleResend}
                    disabled={loading || resendCooldown > 0}
                    className="text-primary underline-offset-4 hover:underline disabled:opacity-50 disabled:cursor-not-allowed disabled:no-underline"
                  >
                    {resendCooldown > 0
                      ? `Nieuwe code aanvragen (${resendCooldown}s)`
                      : "Nieuwe code aanvragen"}
                  </button>
                </p>
              </form>
            )}

            {step === "verify_required" && (
              <div className="space-y-5 text-center">
                <div className="flex justify-center">
                  <MailCheck className="h-12 w-12 text-primary" />
                </div>
                <p className="text-sm text-muted-foreground">
                  Klik op de link in de e-mail om je account te activeren. Daarna kun je inloggen.
                </p>
                <Button
                  type="button"
                  variant="ghost"
                  className="w-full"
                  onClick={() => setStep("credentials")}
                >
                  <ArrowLeft className="mr-2 h-4 w-4" />
                  Terug naar inloggen
                </Button>
              </div>
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

