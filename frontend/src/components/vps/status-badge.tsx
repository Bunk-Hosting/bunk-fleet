import { Badge } from "@/components/ui/badge";
import type { VpsStatus } from "@/lib/types";

const statusConfig: Record<
  VpsStatus,
  { variant: "success" | "secondary" | "warning" | "destructive" | "outline"; label: string }
> = {
  ACTIVE: { variant: "success", label: "Actief" },
  STOPPED: { variant: "secondary", label: "Gestopt" },
  PENDING: { variant: "warning", label: "In wachtrij" },
  PROVISIONING: { variant: "warning", label: "Wordt aangemaakt" },
  ERROR: { variant: "destructive", label: "Fout" },
  DELETING: { variant: "warning", label: "Wordt verwijderd" },
  DELETED: { variant: "outline", label: "Verwijderd" },
};

interface StatusBadgeProps {
  status: VpsStatus;
}

export function StatusBadge({ status }: StatusBadgeProps) {
  const config = statusConfig[status];
  return <Badge variant={config.variant}>{config.label}</Badge>;
}
