"use client";

import * as React from "react";
import { useSearchParams, useRouter } from "next/navigation";
import { ShieldCheck, ShieldOff, ShieldAlert, Loader2, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, parseApiError } from "@/lib/api";
import { useUser } from "@/contexts/UserContext";
import { useToast } from "@/components/ui/use-toast";

type SetupStep = "idle" | "scanning" | "confirming" | "disabling";

function BeveiligingContent() {
  const { user, refresh } = useUser();
  const { toast } = useToast();
  const searchParams = useSearchParams();
  const router = useRouter();

  const isMfaPrompt = searchParams.get("mfa_setup") === "1";

  const [step, setStep] = React.useState<SetupStep>("idle");
  const [qrDataUrl, setQrDataUrl] = React.useState("");
  const [secret, setSecret] = React.useState("");
  const [code, setCode] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [copied, setCopied] = React.useState(false);

  // Auto-start setup wanneer de gebruiker via de MFA-prompt is doorgestuurd
  React.useEffect(() => {
    if (isMfaPrompt && user && !user.totp_enabled && step === "idle") {
      startSetup();
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isMfaPrompt, user]);

  async function startSetup() {
    setLoading(true);
    try {
      const res = await authApi.totp.setup();
      setQrDataUrl(res.data.qr_data_url);
      setSecret(res.data.secret);
      setStep("scanning");
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Fout",
        description: parseApiError(err, "Kon TOTP-setup niet starten."),
      });
    } finally {
      setLoading(false);
    }
  }

  async function confirmSetup(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.totp.confirm(code);
      await refresh();
      setStep("idle");
      setCode("");
      setQrDataUrl("");
      setSecret("");
      toast({ title: "TOTP ingeschakeld", description: "Je account is nu beveiligd met een authenticator-app." });
      if (isMfaPrompt) {
        router.push("/dashboard");
      }
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Ongeldige code",
        description: parseApiError(err, "De ingevoerde code klopt niet. Probeer opnieuw."),
      });
      setCode("");
    } finally {
      setLoading(false);
    }
  }

  async function disableTotp(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.totp.disable(code);
      await refresh();
      setStep("idle");
      setCode("");
      toast({ title: "TOTP uitgeschakeld", description: "Twee-factor-authenticatie is verwijderd." });
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Ongeldige code",
        description: parseApiError(err, "De ingevoerde code klopt niet."),
      });
      setCode("");
    } finally {
      setLoading(false);
    }
  }

  function copySecret() {
    navigator.clipboard.writeText(secret);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (!user) return null;

  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <h1 className="text-2xl font-display font-bold">Beveiliging</h1>
        <p className="text-muted-foreground mt-1">Beheer twee-factor-authenticatie voor je account.</p>
      </div>

      {/* MFA-prompt banner — alleen zichtbaar na eerste inlog zonder TOTP */}
      {isMfaPrompt && !user.totp_enabled && (
        <div className="flex items-start gap-3 rounded-xl border border-primary/30 bg-primary/5 p-4">
          <ShieldAlert className="h-5 w-5 text-primary shrink-0 mt-0.5" />
          <div>
            <p className="font-semibold text-sm">Beveilig je account met een authenticator-app</p>
            <p className="text-sm text-muted-foreground mt-0.5">
              Scan de QR-code hieronder met Google Authenticator, Authy of een andere TOTP-app.
              Hierna heb je naast je wachtwoord altijd een unieke code nodig om in te loggen.
            </p>
          </div>
        </div>
      )}

      {/* TOTP status kaart */}
      <div className="card-gradient-border rounded-xl p-6 bg-card space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            {user.totp_enabled ? (
              <ShieldCheck className="h-8 w-8 text-green-500 shrink-0" />
            ) : (
              <ShieldOff className="h-8 w-8 text-muted-foreground shrink-0" />
            )}
            <div>
              <p className="font-semibold">Authenticator-app (TOTP)</p>
              <p className="text-sm text-muted-foreground">
                {user.totp_enabled
                  ? "Actief — je account is beveiligd met een authenticator-app."
                  : "Niet actief — schakel dit in voor extra beveiliging."}
              </p>
            </div>
          </div>
          <span className={`text-xs font-medium px-2 py-1 rounded-full shrink-0 ${
            user.totp_enabled
              ? "bg-green-500/10 text-green-500"
              : "bg-muted text-muted-foreground"
          }`}>
            {user.totp_enabled ? "Ingeschakeld" : "Uitgeschakeld"}
          </span>
        </div>

        {/* Stap: idle — knoppen tonen */}
        {step === "idle" && (
          <>
            {!user.totp_enabled ? (
              <Button onClick={startSetup} disabled={loading} className="w-full sm:w-auto">
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                TOTP inschakelen
              </Button>
            ) : (
              <Button
                variant="destructive"
                onClick={() => { setStep("disabling"); setCode(""); }}
                className="w-full sm:w-auto"
              >
                TOTP uitschakelen
              </Button>
            )}
          </>
        )}

        {/* Stap: QR-code scannen */}
        {step === "scanning" && (
          <div className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Scan de QR-code met je authenticator-app (Google Authenticator, Authy, Bitwarden, etc.).
            </p>

            {qrDataUrl && (
              <div className="flex justify-center">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={qrDataUrl} alt="TOTP QR-code" className="w-48 h-48 rounded-lg" />
              </div>
            )}

            <div className="space-y-1">
              <p className="text-xs text-muted-foreground">
                Kun je de QR-code niet scannen? Voer deze sleutel handmatig in:
              </p>
              <div className="flex items-center gap-2">
                <code className="flex-1 bg-muted rounded px-3 py-2 text-xs font-mono break-all">
                  {secret}
                </code>
                <Button type="button" variant="outline" size="sm" onClick={copySecret}>
                  {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
                </Button>
              </div>
            </div>

            <Button onClick={() => setStep("confirming")} className="w-full">
              Volgende — code bevestigen
            </Button>
            <Button
              variant="ghost"
              className="w-full"
              onClick={() => {
                setStep("idle");
                setCode("");
                if (isMfaPrompt) router.push("/dashboard");
              }}
            >
              {isMfaPrompt ? "Overslaan — later instellen" : "Annuleren"}
            </Button>
          </div>
        )}

        {/* Stap: code bevestigen */}
        {step === "confirming" && (
          <form onSubmit={confirmSetup} className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Voer de 6-cijferige code in die je authenticator-app nu toont om de setup te bevestigen.
            </p>
            <div className="space-y-2">
              <Label htmlFor="confirm-code">Bevestigingscode</Label>
              <Input
                id="confirm-code"
                type="text"
                inputMode="numeric"
                maxLength={6}
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                required
                autoFocus
                autoComplete="one-time-code"
                className="bg-background/60 text-center tracking-widest text-lg"
              />
            </div>
            <Button type="submit" className="w-full" disabled={loading || code.length !== 6}>
              {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Bevestigen &amp; activeren
            </Button>
            <Button type="button" variant="ghost" className="w-full" onClick={() => setStep("scanning")} disabled={loading}>
              Terug naar QR-code
            </Button>
          </form>
        )}

        {/* Stap: uitschakelen */}
        {step === "disabling" && (
          <form onSubmit={disableTotp} className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Voer een huidige authenticator-code in om TOTP uit te schakelen.
            </p>
            <div className="space-y-2">
              <Label htmlFor="disable-code">Authenticator-code</Label>
              <Input
                id="disable-code"
                type="text"
                inputMode="numeric"
                maxLength={6}
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                required
                autoFocus
                autoComplete="one-time-code"
                className="bg-background/60 text-center tracking-widest text-lg"
              />
            </div>
            <Button type="submit" variant="destructive" className="w-full" disabled={loading || code.length !== 6}>
              {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              TOTP uitschakelen
            </Button>
            <Button type="button" variant="ghost" className="w-full" onClick={() => { setStep("idle"); setCode(""); }} disabled={loading}>
              Annuleren
            </Button>
          </form>
        )}
      </div>

      {/* Uitleg */}
      <div className="text-sm text-muted-foreground space-y-1 px-1">
        <p className="font-medium text-foreground">Wat is TOTP?</p>
        <p>
          TOTP (Time-based One-Time Password) genereert elke 30 seconden een unieke code in je authenticator-app.
          Naast je wachtwoord heb je deze code nodig om in te loggen — zelfs als je wachtwoord uitgelekt is,
          kan niemand zonder je telefoon inloggen.
        </p>
      </div>
    </div>
  );
}

export default function BeveiligingPage() {
  return (
    <React.Suspense fallback={null}>
      <BeveiligingContent />
    </React.Suspense>
  );
}
