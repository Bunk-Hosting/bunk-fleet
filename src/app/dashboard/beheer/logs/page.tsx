"use client";

import { useEffect, useState, useCallback } from "react";
import { Download, Loader2 } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import { cn, formatDateTime } from "@/lib/utils";
import type { AuditLog } from "@/lib/types";

const ACTION_OPTIONS = ["GET", "POST", "PUT", "PATCH", "DELETE"];
const PAGE_SIZE = 25;

function statusCodeColor(code: number | null): string {
  if (code === null) return "";
  if (code >= 200 && code < 300) return "text-green-600 font-medium";
  if (code >= 400 && code < 500) return "text-orange-600 font-medium";
  if (code >= 500) return "text-red-600 font-medium";
  return "";
}

export default function AdminLogsPage() {
  const [logs, setLogs] = useState<AuditLog[]>([]);
  const [loading, setLoading] = useState(true);
  const [totalCount, setTotalCount] = useState(0);
  const [page, setPage] = useState(1);
  const [actionFilter, setActionFilter] = useState<string>("ALL");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [statusCode, setStatusCode] = useState("");
  const { toast } = useToast();

  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE));

  const buildParams = useCallback(() => {
    const params: Record<string, string | number> = {
      page,
      page_size: PAGE_SIZE,
    };
    if (actionFilter !== "ALL") params.action = actionFilter;
    if (dateFrom) params.date_from = dateFrom;
    if (dateTo) params.date_to = dateTo;
    if (statusCode) params.status_code = Number(statusCode);
    return params;
  }, [page, actionFilter, dateFrom, dateTo, statusCode]);

  const fetchLogs = useCallback(async () => {
    setLoading(true);
    try {
      const response = await adminApi.logs.list(buildParams());
      setLogs(response.data.results);
      setTotalCount(response.data.count);
    } catch {
      toast({
        title: "Fout",
        description: "Kon auditlogs niet ophalen.",
        variant: "destructive",
      });
    } finally {
      setLoading(false);
    }
  }, [buildParams, toast]);

  useEffect(() => {
    fetchLogs();
  }, [fetchLogs]);

  useEffect(() => {
    setPage(1);
  }, [actionFilter, dateFrom, dateTo, statusCode]);

  function handleExport() {
    const params: Record<string, string> = {};
    if (actionFilter !== "ALL") params.action = actionFilter;
    if (dateFrom) params.date_from = dateFrom;
    if (dateTo) params.date_to = dateTo;
    if (statusCode) params.status_code = statusCode;
    window.location.href = adminApi.logs.exportUrl(params);
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold">Auditlogs</h1>
        <Button variant="outline" onClick={handleExport}>
          <Download className="mr-2 h-4 w-4" />
          CSV Export
        </Button>
      </div>

      <div className="flex flex-wrap items-end gap-4">
        <div className="space-y-1.5">
          <Label>Actie</Label>
          <Select value={actionFilter} onValueChange={setActionFilter}>
            <SelectTrigger className="w-40">
              <SelectValue placeholder="Alle" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="ALL">Alle</SelectItem>
              {ACTION_OPTIONS.map((action) => (
                <SelectItem key={action} value={action}>
                  {action}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label>Datum van</Label>
          <Input
            type="date"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
            className="w-40"
          />
        </div>
        <div className="space-y-1.5">
          <Label>Datum tot</Label>
          <Input
            type="date"
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
            className="w-40"
          />
        </div>
        <div className="space-y-1.5">
          <Label>Statuscode</Label>
          <Input
            type="number"
            placeholder="bijv. 200"
            value={statusCode}
            onChange={(e) => setStatusCode(e.target.value)}
            className="w-32"
          />
        </div>
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-20">
          <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <>
          <div className="rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>ID</TableHead>
                  <TableHead>Tijdstip</TableHead>
                  <TableHead>Gebruiker</TableHead>
                  <TableHead>Actie</TableHead>
                  <TableHead>Resource</TableHead>
                  <TableHead>Statuscode</TableHead>
                  <TableHead>IP-adres</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {logs.length === 0 ? (
                  <TableRow>
                    <TableCell
                      colSpan={7}
                      className="text-center text-muted-foreground"
                    >
                      Geen logs gevonden.
                    </TableCell>
                  </TableRow>
                ) : (
                  logs.map((log) => (
                    <TableRow key={log.id}>
                      <TableCell>{log.id}</TableCell>
                      <TableCell className="whitespace-nowrap">
                        {formatDateTime(log.timestamp)}
                      </TableCell>
                      <TableCell>{log.user_email ?? "-"}</TableCell>
                      <TableCell>
                        <span className="rounded bg-muted px-2 py-0.5 font-mono text-xs font-medium">
                          {log.action}
                        </span>
                      </TableCell>
                      <TableCell className="max-w-xs truncate font-mono text-xs">
                        {log.resource}
                      </TableCell>
                      <TableCell>
                        <span
                          className={cn(statusCodeColor(log.response_status))}
                        >
                          {log.response_status ?? "-"}
                        </span>
                      </TableCell>
                      <TableCell className="font-mono text-xs">
                        {log.ip_address ?? "-"}
                      </TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </div>

          <div className="flex items-center justify-between">
            <p className="text-sm text-muted-foreground">
              Pagina {page} van {totalPages}
            </p>
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={() => setPage((p) => Math.max(1, p - 1))}
                disabled={page <= 1}
              >
                Vorige
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
                disabled={page >= totalPages}
              >
                Volgende
              </Button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
