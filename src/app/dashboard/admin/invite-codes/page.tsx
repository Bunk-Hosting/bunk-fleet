"use client";

import * as React from "react";
import { Plus, Trash2, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";

interface InviteCode {
  id: number;
  code: string;
  label: string;
  created_by: string | null;
  max_uses: number;
  uses: number;
  expires_at: string | null;
  is_active: boolean;
  is_valid: boolean;
  created_at: string;
}

export default function InviteCodesPage() {
  const { toast } = useToast();
  const [codes, setCodes] = React.useState<InviteCode[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [creating, setCreating] = React.useState(false);
  const [copiedId, setCopiedId] = React.useState<number | null>(null);

  // Formulier
  const [label, setLabel] = React.useState("");
  const [maxUses, setMaxUses] = React.useState("1");
  const [expiresAt, setExpiresAt] = React.useState("");

  const load = React.useCallback(async () => {
    try {
      const res = await adminApi.listInviteCodes();
      setCodes(res.data);
    } catch {
      toast({ variant: "destructive", title: "Fout bij laden van invite codes" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  React.useEffect(() => { load(); }, [load]);

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreating(true);
    try {
      await adminApi.createInviteCode({
        label,
        max_uses: parseInt(maxUses) || 1,
        expires_at: expiresAt || null,
      });
      setLabel("");
      setMaxUses("1");
      setExpiresAt("");
      toast({ title: "Invite code aangemaakt" });
      load();
    } catch {
      toast({ variant: "destructive", title: "Aanmaken mislukt" });
    } finally {
      setCreating(false);
    }
  };

  const handleDelete = async (id: number) => {
    try {
      await adminApi.deleteInviteCode(id);
      toast({ title: "Invite code gedeactiveerd" });
      load();
    } catch {
      toast({ variant: "destructive", title: "Deactiveren mislukt" });
    }
  };

  const handleCopy = (code: InviteCode) => {
    navigator.clipboard.writeText(code.code);
    setCopiedId(code.id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-display font-bold">Invite codes</h1>
        <p className="text-muted-foreground mt-1">
          Genereer codes waarmee nieuwe gebruikers zich kunnen registreren.
        </p>
      </div>

      {/* Nieuwe code aanmaken */}
      <div className="card-gradient-border rounded-xl p-6 bg-card">
        <h2 className="text-base font-semibold mb-4">Nieuwe code aanmaken</h2>
        <form onSubmit={handleCreate} className="grid grid-cols-1 sm:grid-cols-4 gap-4 items-end">
          <div className="space-y-1">
            <Label htmlFor="label">Omschrijving</Label>
            <Input
              id="label"
              placeholder="bijv. voor Jan Jansen"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              className="bg-background/60"
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="max_uses">Max. gebruik</Label>
            <Input
              id="max_uses"
              type="number"
              min="0"
              placeholder="1"
              value={maxUses}
              onChange={(e) => setMaxUses(e.target.value)}
              className="bg-background/60"
            />
            <p className="text-xs text-muted-foreground">0 = onbeperkt</p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="expires_at">Verloopt op</Label>
            <Input
              id="expires_at"
              type="datetime-local"
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
              className="bg-background/60"
            />
          </div>
          <Button type="submit" disabled={creating}>
            <Plus className="h-4 w-4 mr-2" />
            Aanmaken
          </Button>
        </form>
      </div>

      {/* Overzicht */}
      <div className="card-gradient-border rounded-xl bg-card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border/40 text-left">
                <th className="px-4 py-3 font-medium text-muted-foreground">Code</th>
                <th className="px-4 py-3 font-medium text-muted-foreground">Omschrijving</th>
                <th className="px-4 py-3 font-medium text-muted-foreground">Gebruik</th>
                <th className="px-4 py-3 font-medium text-muted-foreground">Verloopt</th>
                <th className="px-4 py-3 font-medium text-muted-foreground">Status</th>
                <th className="px-4 py-3 font-medium text-muted-foreground"></th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                    Laden...
                  </td>
                </tr>
              ) : codes.length === 0 ? (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                    Geen invite codes aangemaakt.
                  </td>
                </tr>
              ) : (
                codes.map((code) => (
                  <tr key={code.id} className="border-b border-border/20 hover:bg-muted/20">
                    <td className="px-4 py-3 font-mono text-xs">
                      <div className="flex items-center gap-2">
                        <span className={code.is_valid ? "" : "line-through text-muted-foreground"}>
                          {code.code}
                        </span>
                        <button
                          onClick={() => handleCopy(code)}
                          className="text-muted-foreground hover:text-foreground transition-colors"
                          title="Kopieer code"
                        >
                          {copiedId === code.id
                            ? <Check className="h-3.5 w-3.5 text-green-500" />
                            : <Copy className="h-3.5 w-3.5" />
                          }
                        </button>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{code.label || "—"}</td>
                    <td className="px-4 py-3">
                      {code.uses}/{code.max_uses === 0 ? "∞" : code.max_uses}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {code.expires_at
                        ? new Date(code.expires_at).toLocaleDateString("nl-NL")
                        : "Nooit"}
                    </td>
                    <td className="px-4 py-3">
                      {code.is_valid ? (
                        <span className="text-green-500 text-xs font-medium">Geldig</span>
                      ) : (
                        <span className="text-destructive text-xs font-medium">
                          {!code.is_active ? "Gedeactiveerd" : "Verlopen/vol"}
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      {code.is_active && (
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-7 w-7 text-muted-foreground hover:text-destructive"
                          onClick={() => handleDelete(code.id)}
                          title="Deactiveer"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
