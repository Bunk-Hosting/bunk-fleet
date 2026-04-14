"use client";
import * as React from "react";
import { Trash2, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { adminApi } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

type AllowedEmail = {
  id: number;
  email: string;
  created_at: string;
  created_by: string | null;
};

export default function AllowedEmailsPage() {
  const { toast } = useToast();
  const [emails, setEmails] = React.useState<AllowedEmail[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [newEmail, setNewEmail] = React.useState("");
  const [adding, setAdding] = React.useState(false);
  const [deletingId, setDeletingId] = React.useState<number | null>(null);

  React.useEffect(() => {
    fetchEmails();
  }, []);

  async function fetchEmails() {
    try {
      const res = await adminApi.listAllowedEmails();
      setEmails(res.data);
    } catch {
      toast({ variant: "destructive", title: "Fout bij ophalen whitelist" });
    } finally {
      setLoading(false);
    }
  }

  async function handleAdd(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = newEmail.trim().toLowerCase();
    if (!trimmed.match(/^[^\s@]+@[^\s@]+\.[^\s@]+$/)) {
      toast({ variant: "destructive", title: "Ongeldig e-mailadres" });
      return;
    }
    setAdding(true);
    try {
      const res = await adminApi.addAllowedEmail(trimmed);
      setEmails((prev) => [res.data, ...prev]);
      setNewEmail("");
      toast({ title: "Toegevoegd", description: trimmed });
    } catch (err: unknown) {
      const e = err as { response?: { data?: { detail?: string } } };
      toast({
        variant: "destructive",
        title: "Fout",
        description: e.response?.data?.detail || "Kon e-mailadres niet toevoegen.",
      });
    } finally {
      setAdding(false);
    }
  }

  async function handleDelete(id: number, email: string) {
    if (!confirm(`Verwijder ${email} van de whitelist?`)) return;
    setDeletingId(id);
    try {
      await adminApi.removeAllowedEmail(id);
      setEmails((prev) => prev.filter((e) => e.id !== id));
      toast({ title: "Verwijderd", description: email });
    } catch {
      toast({ variant: "destructive", title: "Fout bij verwijderen" });
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">E-mail whitelist</h1>
        <p className="text-muted-foreground text-sm mt-1">
          Alleen e-mailadressen op deze lijst kunnen inloggen via OTP.
        </p>
      </div>

      {/* Toevoegen */}
      <form onSubmit={handleAdd} className="flex gap-2 max-w-md">
        <Input
          type="email"
          placeholder="naam@voorbeeld.nl"
          value={newEmail}
          onChange={(e) => setNewEmail(e.target.value)}
          disabled={adding}
          className="bg-background/60"
        />
        <Button type="submit" disabled={adding || !newEmail.trim()}>
          <Plus className="h-4 w-4 mr-1" />
          Toevoegen
        </Button>
      </form>

      {/* Tabel */}
      {loading ? (
        <p className="text-muted-foreground">Laden...</p>
      ) : emails.length === 0 ? (
        <p className="text-muted-foreground">Geen e-mailadressen op de whitelist.</p>
      ) : (
        <div className="rounded-lg border border-border/50 overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-muted/30 text-muted-foreground">
              <tr>
                <th className="text-left px-4 py-3 font-medium">E-mailadres</th>
                <th className="text-left px-4 py-3 font-medium">Toegevoegd op</th>
                <th className="text-left px-4 py-3 font-medium">Door</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody className="divide-y divide-border/30">
              {emails.map((entry) => (
                <tr key={entry.id} className="hover:bg-muted/20 transition-colors">
                  <td className="px-4 py-3 font-mono">{entry.email}</td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {new Date(entry.created_at).toLocaleDateString("nl-NL")}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {entry.created_by || "—"}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-destructive hover:text-destructive hover:bg-destructive/10"
                      onClick={() => handleDelete(entry.id, entry.email)}
                      disabled={deletingId === entry.id}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
