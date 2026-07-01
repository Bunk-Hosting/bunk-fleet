"use client";

import { Loader2, ShieldAlert } from "lucide-react";
import { useUser } from "@/contexts/UserContext";

/**
 * Client-side gate for the admin section. The real authorization is enforced by
 * the API (every /admin/* call requires the :admin role, 403 otherwise); this
 * just avoids rendering an admin shell to a non-admin.
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

  return <>{children}</>;
}
