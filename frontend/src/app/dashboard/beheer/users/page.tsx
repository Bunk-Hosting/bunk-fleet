"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Loader2, Search, Download, ShieldAlert } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import { formatDate, downloadCsv } from "@/lib/utils";
import type { User } from "@/lib/types";

export default function AdminUsersPage() {
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [avgDialogOpen, setAvgDialogOpen] = useState(false);
  const { toast } = useToast();

  function handleExport() {
    const rows = users.map((u) => ({
      "ID": u.id,
      "Naam": u.name,
      "E-mailadres": u.email,
      "Rol": u.role,
      "Aangemeld op": new Date(u.date_joined).toLocaleDateString("nl-NL"),
      "Actief": u.is_active ? "Ja" : "Nee",
      "Aantal VPS'en": u.vps_count ?? 0,
    }));

    const date = new Date().toISOString().slice(0, 10);
    downloadCsv(`gebruikers-${date}.csv`, rows);

    setAvgDialogOpen(false);
    toast({ title: "Export klaar", description: "Het CSV-bestand is gedownload." });
  }

  useEffect(() => {
    async function fetchUsers() {
      try {
        const response = await adminApi.users.list();
        setUsers(response.data.results);
      } catch {
        toast({
          title: "Fout",
          description: "Kon gebruikers niet ophalen.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    fetchUsers();
  }, [toast]);

  // useMemo voorkomt dat we de hele user-lijst opnieuw door filter() halen bij
  // elke keystroke/render. Bij honderden users is dit anders O(n) per render.
  const filteredUsers = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return users;
    return users.filter((user) =>
      user.name.toLowerCase().includes(term) ||
      user.email.toLowerCase().includes(term)
    );
  }, [users, search]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold">Gebruikersbeheer</h1>
        <Button variant="outline" size="sm" onClick={() => setAvgDialogOpen(true)} disabled={loading}>
          <Download className="mr-2 h-4 w-4" />
          Exporteer Excel
        </Button>
      </div>

      <div className="relative max-w-sm">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="Zoek op naam of e-mail..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="pl-9"
        />
      </div>

      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Naam</TableHead>
              <TableHead>E-mail</TableHead>
              <TableHead>Rol</TableHead>
              <TableHead>VPS&apos;en</TableHead>
              <TableHead>Lid sinds</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Acties</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filteredUsers.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} className="text-center text-muted-foreground">
                  Geen gebruikers gevonden.
                </TableCell>
              </TableRow>
            ) : (
              filteredUsers.map((user) => (
                <TableRow key={user.id}>
                  <TableCell className="font-medium">{user.name}</TableCell>
                  <TableCell>{user.email}</TableCell>
                  <TableCell>
                    <Badge variant={user.role === "admin" ? "default" : "secondary"}>
                      {user.role}
                    </Badge>
                  </TableCell>
                  <TableCell>{user.vps_count ?? 0}</TableCell>
                  <TableCell>{formatDate(user.date_joined)}</TableCell>
                  <TableCell>
                    <Badge variant={user.is_active ? "success" : "destructive"}>
                      {user.is_active ? "Actief" : "Inactief"}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <Link href={`/dashboard/beheer/users/${user.id}`}>
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

      <Dialog open={avgDialogOpen} onOpenChange={setAvgDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <ShieldAlert className="h-5 w-5 text-orange-500" />
              Persoonsgegevens exporteren
            </DialogTitle>
            <DialogDescription asChild>
              <div className="space-y-3 text-sm">
                <p>
                  Dit bestand bevat <strong>persoonsgegevens</strong> (naam, e-mailadres)
                  en valt onder de <strong>AVG (GDPR)</strong>.
                </p>
                <ul className="list-disc pl-5 space-y-1 text-muted-foreground">
                  <li>Gebruik het bestand alleen voor het beoogde doel.</li>
                  <li>Sla het op een beveiligde locatie op.</li>
                  <li>Deel het niet met onbevoegden.</li>
                  <li>Verwijder het zodra het niet meer nodig is.</li>
                </ul>
                <p className="text-muted-foreground">
                  De download wordt vastgelegd in het auditlog (ISO 27001).
                </p>
              </div>
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setAvgDialogOpen(false)}>
              Annuleren
            </Button>
            <Button onClick={handleExport}>
              <Download className="mr-2 h-4 w-4" />
              Exporteren
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
