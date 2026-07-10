"use client";

import * as React from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { CheckCircle, XCircle, Loader2, Server } from "lucide-react";
import { Button } from "@/components/ui/button";
import { authApi, parseApiError } from "@/lib/api";

function VerifyEmailContent() {
  const searchParams = useSearchParams();
  const token = searchParams.get("token") ?? "";

  const [status, setStatus] = React.useState<"loading" | "success" | "error">("loading");
  const [message, setMessage] = React.useState("");

  React.useEffect(() => {
    if (!token) {
      setStatus("error");
      setMessage("Geen verificatietoken gevonden in de link.");
      return;
    }

    authApi
      .verifyEmail(token)
      .then(() => {
        setStatus("success");
        setMessage("Je e-mailadres is succesvol bevestigd. Je kunt nu inloggen.");
      })
      .catch((err) => {
        setStatus("error");
        setMessage(parseApiError(err, "De link is ongeldig of verlopen."));
      });
  }, [token]);

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      {/* Ambient glow orbs */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      {/* Header */}
      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10">
        <div className="max-w-7xl mx-auto flex justify-between items-center px-6 lg:px-8 h-16 w-full">
          <a href={process.env.NEXT_PUBLIC_WEBSITE_URL || "/"} className="flex items-center gap-3">
            <Server className="h-6 w-6 text-accent" />
            <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
          </a>
        </div>
      </header>

      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          <div className="card-gradient-border rounded-xl p-8 bg-card text-center">
            {status === "loading" && (
              <>
                <Loader2 className="h-12 w-12 animate-spin text-accent mx-auto mb-4" />
                <h1 className="text-xl font-display font-bold mb-2">Bezig met verifiëren…</h1>
                <p className="text-muted-foreground text-sm">Even geduld.</p>
              </>
            )}

            {status === "success" && (
              <>
                <CheckCircle className="h-12 w-12 text-green-500 mx-auto mb-4" />
                <h1 className="text-xl font-display font-bold mb-2">E-mail bevestigd!</h1>
                <p className="text-muted-foreground text-sm mb-6">{message}</p>
                <Button asChild className="w-full">
                  <Link href="/login">Inloggen</Link>
                </Button>
              </>
            )}

            {status === "error" && (
              <>
                <XCircle className="h-12 w-12 text-destructive mx-auto mb-4" />
                <h1 className="text-xl font-display font-bold mb-2">Verificatie mislukt</h1>
                <p className="text-muted-foreground text-sm mb-6">{message}</p>
                <div className="flex flex-col gap-3">
                  <Button asChild variant="outline" className="w-full">
                    <Link href="/login">Terug naar inloggen</Link>
                  </Button>
                </div>
              </>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

export default function VerifyEmailPage() {
  return (
    <React.Suspense fallback={null}>
      <VerifyEmailContent />
    </React.Suspense>
  );
}
