"use client";

import { useEffect, useState, useCallback } from "react";
import { Network, Globe, CheckCircle2, Lock, Loader2, Download } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import { formatDate, downloadCsv } from "@/lib/utils";
import type { IPAddressEntry, IPAddressStatus, NetworkSummary } from "@/lib/types";

const STATUS_LABELS: Record<IPAddressStatus, string> = {
  FREE: "Vrij",
  ASSIGNED: "Toegewezen",
  RESERVED: "Gereserveerd",
};

const STATUS_VARIANTS: Record<IPAddressStatus, "default" | "secondary" | "destructive" | "outline"> = {
  FREE: "secondary",
  ASSIGNED: "default",
  RESERVED: "outline",
};

function SummaryCard({
  title,
  value,
  icon: Icon,
  color,
}: {
  title: string;
  value: number;
  icon: React.ElementType;
  color: string;
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium">{title}</CardTitle>
        <Icon className={`h-4 w-4 ${color}`} />
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-bold">{value.toLocaleString()}</div>
      </CardContent>
    </Card>
  );
}

function exportExcel(entries: IPAddressEntry[], filter: string) {
  const rows = entries.map((e) => ({
    "IP-adres": e.address,
    "Status": STATUS_LABELS[e.status],
    "VM-naam": e.infra_name ?? "",
    "Pakket": e.package_name ?? "",
    "Eigenaar": e.owner_email ?? "",
    "Toegewezen op": e.assigned_at ? new Date(e.assigned_at).toLocaleDateString("nl-NL") : "",
  }));

  const suffix = filter !== "ALL" ? `-${filter.toLowerCase()}` : "";
  downloadCsv(`ip-plan${suffix}-${new Date().toISOString().slice(0, 10)}.csv`, rows);
}

export default function AdminNetworkPage() {
  const [entries, setEntries] = useState<IPAddressEntry[]>([]);
  const [summary, setSummary] = useState<NetworkSummary | null>(null);
  const [statusFilter, setStatusFilter] = useState<IPAddressStatus | "ALL">("ALL");
  const [loading, setLoading] = useState(true);
  const { toast } = useToast();

  const fetchData = useCallback(async () => {
    setLoading(true);
    try {
      const params = statusFilter !== "ALL" ? { status: statusFilter } : undefined;
      const response = await adminApi.network.list(params);
      setSummary(response.data.summary);
      setEntries(response.data.results);
    } catch {
      toast({
        title: "Fout",
        description: "Kon netwerkoverzicht niet ophalen.",
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  }, [statusFilter, toast]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Netwerk — IP-pool</h1>
        <p className="text-muted-foreground">
          Overzicht van alle IP-adressen in VLAN 30 (10.10.0.0/19)
        </p>
      </div>

      {/* Samenvatting */}
      {summary && (
        <div className="grid gap-4 md:grid-cols-4">
          <SummaryCard
            title="Totaal"
            value={summary.total}
            icon={Network}
            color="text-muted-foreground"
          />
          <SummaryCard
            title="Vrij"
            value={summary.free}
            icon={Globe}
            color="text-green-500"
          />
          <SummaryCard
            title="Toegewezen"
            value={summary.assigned}
            icon={CheckCircle2}
            color="text-blue-500"
          />
          <SummaryCard
            title="Gereserveerd"
            value={summary.reserved}
            icon={Lock}
            color="text-orange-500"
          />
        </div>
      )}

      {/* Filter + export */}
      <div className="flex flex-wrap items-center gap-3">
        <span className="text-sm text-muted-foreground">Filter op status:</span>
        <Select
          value={statusFilter}
          onValueChange={(v) => setStatusFilter(v as IPAddressStatus | "ALL")}
        >
          <SelectTrigger className="w-48">
            <SelectValue placeholder="Alle statussen" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="ALL">Alle statussen</SelectItem>
            <SelectItem value="FREE">Vrij</SelectItem>
            <SelectItem value="ASSIGNED">Toegewezen</SelectItem>
            <SelectItem value="RESERVED">Gereserveerd</SelectItem>
          </SelectContent>
        </Select>
        <span className="text-sm text-muted-foreground">
          {loading ? "Laden…" : `${entries.length.toLocaleString()} adressen`}
        </span>
        <div className="ml-auto">
          <Button
            variant="outline"
            size="sm"
            disabled={loading || entries.length === 0}
            onClick={() => exportExcel(entries, statusFilter)}
          >
            <Download className="mr-2 h-4 w-4" />
            Exporteer Excel
          </Button>
        </div>
      </div>

      {/* Tabel */}
      {loading ? (
        <div className="flex items-center justify-center py-20">
          <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>IP-adres</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>VM-naam</TableHead>
                <TableHead>Pakket</TableHead>
                <TableHead>Eigenaar</TableHead>
                <TableHead>Toegewezen op</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {entries.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={6} className="text-center text-muted-foreground py-8">
                    Geen IP-adressen gevonden.
                  </TableCell>
                </TableRow>
              ) : (
                entries.map((entry) => (
                  <TableRow key={entry.id}>
                    <TableCell className="font-mono text-sm">{entry.address}</TableCell>
                    <TableCell>
                      <Badge variant={STATUS_VARIANTS[entry.status]}>
                        {STATUS_LABELS[entry.status]}
                      </Badge>
                    </TableCell>
                    <TableCell className="font-mono text-sm">
                      {entry.infra_name ?? "—"}
                    </TableCell>
                    <TableCell>{entry.package_name ?? "—"}</TableCell>
                    <TableCell className="text-sm">{entry.owner_email ?? "—"}</TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {entry.assigned_at ? formatDate(entry.assigned_at) : "—"}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
