"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
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

export default function ResetPasswordPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { toast } = useToast();

  const token = searchParams.get("token") ?? "";

  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (password !== passwordConfirm) {
      toast({
        variant: "destructive",
        title: "Wachtwoorden komen niet overeen",
        description: "Controleer of je wachtwoorden gelijk zijn.",
      });
      return;
    }

    setLoading(true);
    try {
      await authApi.passwordResetConfirm(token, password, passwordConfirm);
      toast({
        title: "Wachtwoord gewijzigd",
        description: "Je kunt nu inloggen met je nieuwe wachtwoord.",
      });
      router.push("/login");
    } catch (err: unknown) {
      const error = err as { response?: { data?: { detail?: string | string[] } } };
      const detail = error.response?.data?.detail;
      toast({
        variant: "destructive",
        title: "Fout",
        description: Array.isArray(detail) ? detail.join(" ") : (detail ?? "De resetlink is ongeldig of verlopen."),
      });
    } finally {
      setLoading(false);
    }
  };

  if (!token) {
    return (
      <div className="min-h-screen flex flex-col">
        <Navbar />
        <main className="flex-1 flex items-center justify-center py-12">
          <Card className="w-full max-w-md mx-4">
            <CardContent className="pt-6 text-center space-y-4">
              <p className="text-muted-foreground">Ongeldige resetlink.</p>
              <Link href="/forgot-password">
                <Button variant="outline">Nieuwe resetlink aanvragen</Button>
              </Link>
            </CardContent>
          </Card>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex flex-col">
      <Navbar />
      <main className="flex-1 flex items-center justify-center py-12">
        <Card className="w-full max-w-md mx-4">
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">Nieuw wachtwoord instellen</CardTitle>
            <CardDescription>Kies een sterk wachtwoord van minimaal 8 tekens.</CardDescription>
          </CardHeader>
          <form onSubmit={handleSubmit}>
            <CardContent className="space-y-4">
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
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="password-confirm">Wachtwoord bevestigen</Label>
                <Input
                  id="password-confirm"
                  type="password"
                  placeholder="••••••••"
                  value={passwordConfirm}
                  onChange={(e) => setPasswordConfirm(e.target.value)}
                  required
                  disabled={loading}
                />
              </div>
            </CardContent>
            <CardFooter>
              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Wachtwoord opslaan
              </Button>
            </CardFooter>
          </form>
        </Card>
      </main>
    </div>
  );
}
