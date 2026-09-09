"use client";

import * as React from "react";
import { MailWarning, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { authApi, parseApiError } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";
import type { User } from "@/lib/types";

/**
 * Shown at the top of the dashboard while the account's email is unconfirmed.
 * Confirmation itself happens on /verify-email (from the emailed link); this
 * banner only offers to resend that email if it never arrived.
 */
export function UnconfirmedEmailBanner({ user }: { user: User }) {
  const { toast } = useToast();
  const [sending, setSending] = React.useState(false);
  const [sent, setSent] = React.useState(false);

  if (user.confirmed_at) return null;

  const handleResend = async () => {
    setSending(true);
    try {
      await authApi.resendConfirmation();
      setSent(true);
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Versturen mislukt",
        description: parseApiError(err, "Kon de bevestigingsmail niet opnieuw versturen."),
      });
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="mb-6 flex flex-col gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 p-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-start gap-3">
        <MailWarning className="mt-0.5 h-5 w-5 shrink-0 text-amber-500" />
        <p className="text-sm text-foreground">
          Bevestig je e-mailadres ({user.email}) om je welkomstkrediet te ontvangen. Check je inbox voor de link.
        </p>
      </div>
      <Button
        variant="outline"
        size="sm"
        className="shrink-0 border-amber-500/40"
        disabled={sending || sent}
        onClick={handleResend}
      >
        {sending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
        {sent ? "E-mail verstuurd" : "Opnieuw versturen"}
      </Button>
    </div>
  );
}
