"use client";

import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { Loader2 } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import { formatDate, getOsLabel, formatPrice } from "@/lib/utils";
import type { Vps, VpsStatus, OsChoice } from "@/lib/types";

const ALL_STATUSES: VpsStatus[] = [
  "PENDING",
  "PROVISIONING",
  "ACTIVE",
  "STOPPED",
  "DELETING",
  "DELETED",
  "ERROR",
];

const ALL_OS: OsChoice[] = [
  "ubuntu-22.04",
  "ubuntu-20.04",
  "debian-12",
  "debian-11",
  "centos-9",
  "alpine-3.19",
];

export default function AdminVpsPage() {
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<string>("ALL");
  const [osFilter, setOsFilter] = useState<string>("ALL");
  const { toast } = useToast();

  const fetchVps = useCallback(async () => {
    setLoading(true);
    try {
      const params: { status?: VpsStatus; os?: OsChoice } = {};
      if (statusFilter !== "ALL") params.status = statusFilter as VpsStatus;
      if (osFilter !== "ALL") params.os = osFilter as OsChoice;
      const response = await adminApi.vps.list(params);
      setVpsList(response.data.results);
    } catch {
      toast({
        title: "Fout",
        description: "Kon VPS-lijst niet ophalen.",
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  }, [statusFilter, osFilter, toast]);

  useEffect(() => {
    fetchVps();
  }, [fetchVps]);

  return (
    <div className="space-y-6">
      <h1 className="text-3xl font-bold">VPS Beheer</h1>

      <div className="flex flex-wrap gap-4">
        <div className="w-48">
          <Select value={statusFilter} onValueChange={setStatusFilter}>
            <SelectTrigger>
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="ALL">Alle statussen</SelectItem>
              {ALL_STATUSES.map((s) => (
                <SelectItem key={s} value={s}>
                  {s}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="w-48">
          <Select value={osFilter} onValueChange={setOsFilter}>
            <SelectTrigger>
              <SelectValue placeholder="OS" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="ALL">Alle OS</SelectItem>
              {ALL_OS.map((os) => (
                <SelectItem key={os} value={os}>
                  {getOsLabel(os)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-20">
          <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>ID</TableHead>
                <TableHead>Label</TableHead>
                <TableHead>Eigenaar</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>OS</TableHead>
                <TableHead>Pakket</TableHead>
                <TableHead>IP</TableHead>
                <TableHead>Aangemaakt</TableHead>
                <TableHead>Acties</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {vpsList.length === 0 ? (
                <TableRow>
                  <TableCell
                    colSpan={9}
                    className="text-center text-muted-foreground"
                  >
                    Geen VPS&apos;en gevonden.
                  </TableCell>
                </TableRow>
              ) : (
                vpsList.map((vps) => (
                  <TableRow key={vps.id}>
                    <TableCell>{vps.id}</TableCell>
                    <TableCell className="font-medium">{vps.label}</TableCell>
                    <TableCell>{vps.owner_email ?? vps.owner}</TableCell>
                    <TableCell>
                      <StatusBadge status={vps.status} />
                    </TableCell>
                    <TableCell>{getOsLabel(vps.os)}</TableCell>
                    <TableCell>
                      {vps.package.name} ({formatPrice(vps.package.price_monthly)}/mnd)
                    </TableCell>
                    <TableCell>{vps.ip_address ?? "-"}</TableCell>
                    <TableCell>{formatDate(vps.created_at)}</TableCell>
                    <TableCell>
                      <Link href={`/dashboard/beheer/vps/${vps.id}`}>
                        <Button variant="outline" size="sm">
                          Bekijken
                        </Button>
                      </Link>
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
