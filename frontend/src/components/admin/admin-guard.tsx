"use client";

import Link from "next/link";
import { Loader2, ShieldAlert, ShieldOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useUser } from "@/contexts/UserContext";

/**
 * Client-side gate for the admin section. The real authorization is enforced by
 * the API (every /admin/* call requires the :admin role, 403 otherwise); this
 * just avoids rendering an admin shell to a non-admin.
 *
 * Het beheerpaneel eist daarnaast een tweede factor. Ook dat wordt afgedwongen
 * door de API; hier staat het alleen om een beheerder die er geen heeft uit te
 * leggen wat er aan de hand is en waar hij het aanzet. Zonder dit zou hij een
 * scherm vol mislukte verzoeken zien en zelf moeten raden waarom.
 */
export function AdminGuard({ children }: { children: React.ReactNode }) {
  const { user, loading } = useUser();

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!user || user.role !== "admin") {
    return (
      <div className="flex flex-col items-center justify-center py-20 text-center">
        <ShieldAlert className="mb-3 h-10 w-10 text-muted-foreground" />
        <p className="text-muted-foreground">
          Geen toegang — deze pagina is alleen voor beheerders.
        </p>
      </div>
    );
  }

  if (!user.totp_enabled && !user.passkeys_enabled) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-20 text-center">
        <ShieldOff className="h-10 w-10 text-muted-foreground" />
        <div>
          <p className="font-medium">Het beheerpaneel vraagt een tweede factor</p>
          <p className="mx-auto mt-1 max-w-md text-sm text-muted-foreground">
            Hierachter staat elk klantaccount, elke VPS en de knop die tegoed bijboekt. Eén
            wachtwoord is daar te weinig voor. Zet een authenticator-app of een passkey aan;
            daarna kun je hier meteen verder.
          </p>
        </div>
        <Link href="/dashboard/beveiliging">
          <Button>Naar Beveiliging</Button>
        </Link>
      </div>
    );
  }

  return <>{children}</>;
}
