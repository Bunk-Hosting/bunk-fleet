"use client";

import * as React from "react";
import Link from "next/link";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@/components/ui/card";
import { Navbar } from "@/components/layout/navbar";
import { authApi } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

export default function ForgotPasswordPage() {
  const { toast } = useToast();
  const [email, setEmail] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [submitted, setSubmitted] = React.useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.passwordResetRequest(email);
      setSubmitted(true);
    } catch {
      toast({
        variant: "destructive",
        title: "Er is iets misgegaan",
        description: "Probeer het later opnieuw.",
      });
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex flex-col">
      <Navbar />
      <main className="flex-1 flex items-center justify-center py-12">
        <Card className="w-full max-w-md mx-4">
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">Wachtwoord vergeten</CardTitle>
            <CardDescription>
              Voer je e-mailadres in en ontvang een resetlink.
            </CardDescription>
          </CardHeader>

          {submitted ? (
            <CardContent className="text-center space-y-4">
              <p className="text-sm text-muted-foreground">
                Als dit e-mailadres bekend is, ontvang je binnen enkele minuten een resetlink.
              </p>
              <p className="text-sm text-muted-foreground">
                Controleer ook je spam-map.
              </p>
              <Link href="/login">
                <Button variant="outline" className="w-full">Terug naar inloggen</Button>
              </Link>
            </CardContent>
          ) : (
            <form onSubmit={handleSubmit}>
              <CardContent className="space-y-4">
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
                  />
                </div>
              </CardContent>
              <CardFooter className="flex flex-col gap-4">
                <Button type="submit" className="w-full" disabled={loading}>
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Resetlink versturen
                </Button>
                <p className="text-sm text-muted-foreground text-center">
                  <Link href="/login" className="text-primary hover:underline">
                    Terug naar inloggen
                  </Link>
                </p>
              </CardFooter>
            </form>
          )}
        </Card>
      </main>
    </div>
  );
}
