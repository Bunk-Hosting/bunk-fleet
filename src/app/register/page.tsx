"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
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

export default function RegisterPage() {
  const router = useRouter();
  const { toast } = useToast();

  const [name, setName] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [errors, setErrors] = React.useState<Record<string, string[]>>({});

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrors({});

    if (password !== passwordConfirm) {
      setErrors({ password_confirm: ["Wachtwoorden komen niet overeen."] });
      return;
    }

    setLoading(true);

    try {
      await authApi.register({
        name,
        email,
        password,
        password_confirm: passwordConfirm,
      });
      router.push("/dashboard");
    } catch (err: unknown) {
      const error = err as {
        response?: { data?: Record<string, string[] | string> };
      };
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
    <div className="min-h-screen flex flex-col">
      <Navbar />

      <main className="flex-1 flex items-center justify-center py-12">
        <Card className="w-full max-w-md mx-4">
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">Registreren</CardTitle>
            <CardDescription>
              Maak een nieuw Bunk Hosting account aan
            </CardDescription>
          </CardHeader>
          <form onSubmit={handleSubmit}>
            <CardContent className="space-y-4">
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
                />
                {errors.password && (
                  <p className="text-sm text-destructive">
                    {errors.password[0]}
                  </p>
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
                />
                {errors.password_confirm && (
                  <p className="text-sm text-destructive">
                    {errors.password_confirm[0]}
                  </p>
                )}
              </div>
            </CardContent>
            <CardFooter className="flex flex-col gap-4">
              <Button type="submit" className="w-full" disabled={loading}>
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Registreren
              </Button>
              <p className="text-sm text-muted-foreground text-center">
                Al een account?{" "}
                <Link href="/login" className="text-primary hover:underline">
                  Log hier in
                </Link>
              </p>
            </CardFooter>
          </form>
        </Card>
      </main>
    </div>
  );
}
