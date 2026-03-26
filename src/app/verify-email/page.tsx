"use client";

import * as React from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Loader2, CheckCircle, XCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
import { Navbar } from "@/components/layout/navbar";
import { authApi } from "@/lib/api";

type State = "loading" | "success" | "error";

export default function VerifyEmailPage() {
  const searchParams = useSearchParams();
  const token = searchParams.get("token") ?? "";
  const [state, setState] = React.useState<State>("loading");

  React.useEffect(() => {
    if (!token) {
      setState("error");
      return;
    }
    authApi
      .verifyEmail(token)
      .then(() => setState("success"))
      .catch(() => setState("error"));
  }, [token]);

  return (
    <div className="min-h-screen flex flex-col">
      <Navbar />
      <main className="flex-1 flex items-center justify-center py-12">
        <Card className="w-full max-w-md mx-4">
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">E-mailverificatie</CardTitle>
          </CardHeader>
          <CardContent className="text-center space-y-6">
            {state === "loading" && (
              <>
                <Loader2 className="mx-auto h-12 w-12 animate-spin text-primary" />
                <CardDescription>Je e-mailadres wordt bevestigd...</CardDescription>
              </>
            )}
            {state === "success" && (
              <>
                <CheckCircle className="mx-auto h-12 w-12 text-green-500" />
                <p className="text-sm text-muted-foreground">
                  Je e-mailadres is succesvol bevestigd. Je kunt nu volledig gebruik maken van je account.
                </p>
                <Link href="/dashboard">
                  <Button className="w-full">Naar dashboard</Button>
                </Link>
              </>
            )}
            {state === "error" && (
              <>
                <XCircle className="mx-auto h-12 w-12 text-destructive" />
                <p className="text-sm text-muted-foreground">
                  De verificatielink is ongeldig of verlopen. Vraag een nieuwe link aan via je dashboard.
                </p>
                <Link href="/login">
                  <Button variant="outline" className="w-full">Terug naar inloggen</Button>
                </Link>
              </>
            )}
          </CardContent>
        </Card>
      </main>
    </div>
  );
}
