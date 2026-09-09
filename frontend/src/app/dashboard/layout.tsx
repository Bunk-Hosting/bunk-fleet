"use client";

import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Sidebar } from "@/components/layout/sidebar";
import { UnconfirmedEmailBanner } from "@/components/layout/unconfirmed-email-banner";
import { UserProvider, useUser } from "@/contexts/UserContext";

function DashboardShell({ children }: { children: React.ReactNode }) {
  const { user, loading, error, refresh } = useUser();

  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!user) {
    if (error) {
      return (
        <div className="flex h-screen flex-col items-center justify-center gap-4 p-4 text-center">
          <p className="text-muted-foreground">
            Kon je sessie niet laden. Controleer je verbinding en probeer het opnieuw.
          </p>
          <Button onClick={() => refresh()}>Opnieuw proberen</Button>
        </div>
      );
    }
    return null;
  }

  return (
    <div className="min-h-screen bg-background bg-dot-grid">
      {/* Ambient glow orbs — exact match bunkhosting.nl */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>
      <Sidebar user={user} />
      <div className="relative z-0 md:pl-64">
        <main className="p-4 md:p-8">
          <UnconfirmedEmailBanner user={user} />
          {children}
        </main>
      </div>
    </div>
  );
}

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <UserProvider>
      <DashboardShell>{children}</DashboardShell>
    </UserProvider>
  );
}
