import { cn } from "@/lib/utils";
import type { VpsStatus } from "@/lib/types";

// Eén stip plus een woord, in plaats van een volgekleurde pil.
//
// De vorige versie viel om twee redenen uit de toon. De kleuren waren vol
// verzadigd (bg-green-500 met witte tekst) terwijl de rest van het dashboard
// ingetogen is, en de labels liepen sterk uiteen in lengte — "Actief" naast
// "Back-up terugzetten" — waardoor de badge bij de ene VPS twee keer zo breed
// was als bij de andere. Vandaar: kortere woorden, een vaste hoogte, en kleur
// die alleen in de stip zit. De stip draagt de betekenis, de tekst bevestigt
// hem; dat leest sneller en schreeuwt niet.
const statusConfig: Record<
  VpsStatus,
  { label: string; dot: string; tint: string; busy?: boolean }
> = {
  ACTIVE: {
    label: "Actief",
    dot: "bg-emerald-500",
    tint: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
  },
  STOPPED: {
    label: "Gestopt",
    dot: "bg-muted-foreground",
    tint: "bg-muted text-muted-foreground",
  },
  PENDING: {
    label: "In wachtrij",
    dot: "bg-amber-500",
    tint: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
    busy: true,
  },
  PROVISIONING: {
    label: "Aanmaken",
    dot: "bg-amber-500",
    tint: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
    busy: true,
  },
  RESTORING: {
    label: "Terugzetten",
    dot: "bg-amber-500",
    tint: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
    busy: true,
  },
  DELETING: {
    label: "Verwijderen",
    dot: "bg-amber-500",
    tint: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
    busy: true,
  },
  ERROR: {
    label: "Fout",
    dot: "bg-destructive",
    tint: "bg-destructive/10 text-destructive",
  },
  DELETED: {
    label: "Verwijderd",
    dot: "bg-muted-foreground/50",
    tint: "bg-muted text-muted-foreground",
  },
};

interface StatusBadgeProps {
  status: VpsStatus;
  className?: string;
}

export function StatusBadge({ status, className }: StatusBadgeProps) {
  const config = statusConfig[status];

  return (
    <span
      className={cn(
        // h-6 vast: zo houdt een kaart dezelfde regelhoogte, ongeacht de status.
        "inline-flex h-6 shrink-0 items-center gap-1.5 rounded-full px-2.5 text-xs font-medium",
        config.tint,
        className,
      )}
    >
      <span className="relative flex h-1.5 w-1.5 shrink-0">
        {/* Alleen bij een overgangstoestand een pulserende ring: dan zegt de
            badge "er gebeurt iets" zonder dat je op de tekst hoeft te letten. */}
        {config.busy && (
          <span
            className={cn(
              "absolute inline-flex h-full w-full animate-ping rounded-full opacity-60",
              config.dot,
            )}
          />
        )}
        <span className={cn("relative inline-flex h-1.5 w-1.5 rounded-full", config.dot)} />
      </span>
      {config.label}
    </span>
  );
}
