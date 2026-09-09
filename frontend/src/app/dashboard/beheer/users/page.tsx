"use client";

import { useEffect, useState } from "react";
import { Loader2, Search, Plus } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, parseApiError, type AdminUser } from "@/lib/api";
import { formatEuro } from "@/lib/utils";

const ROLES = ["user", "admin"] as const;

function UsersInner() {
  const { toast } = useToast();
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const load = () =>
    adminApi
      .users()
      .then(setUsers)
      .catch(() => toast({ title: "Fout", description: "Kon gebruikers niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function changeRole(u: AdminUser, role: "user" | "admin") {
    if (role === u.role) return;
    setBusy(u.id);
    try {
      await adminApi.setRole(u.id, role);
      setUsers((prev) => prev.map((x) => (x.id === u.id ? { ...x, role } : x)));
      toast({ title: "Rol gewijzigd", description: `${u.email} → ${role}` });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon rol niet wijzigen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  async function addCredit(u: AdminUser) {
    const input = window.prompt(`Tegoed aanpassen voor ${u.email} (in euro, bijv. 10 of -5):`, "10");
    if (input === null) return;
    const euros = Number(input.replace(",", "."));
    if (!Number.isFinite(euros) || euros === 0) {
      toast({ title: "Ongeldig bedrag", variant: "destructive" });
      return;
    }
    setBusy(u.id);
    try {
      const res = await adminApi.addCredit(u.id, Math.round(euros * 100));
      setUsers((prev) => prev.map((x) => (x.id === u.id ? { ...x, balance_cents: res.data.balance_cents } : x)));
      toast({ title: "Tegoed aangepast", description: `${u.email}: ${formatEuro(res.data.balance_cents / 100)}` });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon tegoed niet aanpassen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  const filtered = users.filter(
    (u) => u.email.toLowerCase().includes(q.toLowerCase()) || u.name.toLowerCase().includes(q.toLowerCase())
  );

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Gebruikers</h1>
        <p className="text-muted-foreground">{users.length} accounts — rol wijzigen en tegoed aanpassen.</p>
      </div>

      <div className="relative max-w-sm">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input placeholder="Zoek op e-mail of naam" value={q} onChange={(e) => setQ(e.target.value)} className="pl-9" />
      </div>

      <Card>
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">Gebruiker</th>
                  <th className="px-4 py-3">Rol</th>
                  <th className="px-4 py-3">VPS&apos;en</th>
                  <th className="px-4 py-3">Tegoed</th>
                  <th className="px-4 py-3">2FA</th>
                  <th className="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((u) => (
                  <tr key={u.id} className="border-b last:border-0">
                    <td className="px-4 py-3">
                      <div className="font-medium">{u.name || "—"}</div>
                      <div className="text-xs text-muted-foreground">{u.email}</div>
                    </td>
                    <td className="px-4 py-3">
                      <Select value={u.role} onValueChange={(v) => changeRole(u, v as "user" | "admin")}>
                        <SelectTrigger className="h-8 w-32"><SelectValue /></SelectTrigger>
                        <SelectContent>
                          {ROLES.map((r) => (
                            <SelectItem key={r} value={r}>{r}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </td>
                    <td className="px-4 py-3">{u.vps_count}</td>
                    <td className="px-4 py-3 font-medium">{formatEuro(u.balance_cents / 100)}</td>
                    <td className="px-4 py-3">
                      {u.two_factor ? <Badge variant="default">aan</Badge> : <Badge variant="secondary">uit</Badge>}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <Button variant="outline" size="sm" disabled={busy === u.id} onClick={() => addCredit(u)}>
                        {busy === u.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="mr-1 h-4 w-4" />}
                        Tegoed
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

export default function AdminUsersPage() {
  return (
    <AdminGuard>
      <UsersInner />
    </AdminGuard>
  );
}
