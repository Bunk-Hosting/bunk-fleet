"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Loader2, AlertCircle } from "lucide-react";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { adminApi, authApi } from "@/lib/api";
import { formatDate, getOsLabel } from "@/lib/utils";
import type { User, Vps } from "@/lib/types";

export default function AdminUserDetailPage() {
  const params = useParams();
  const router = useRouter();
  const userId = Number(params.id);
  const { toast } = useToast();

  const [user, setUser] = useState<User | null>(null);
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [loading, setLoading] = useState(true);
  const [currentUserId, setCurrentUserId] = useState<number | null>(null);
  const [roleDialogOpen, setRoleDialogOpen] = useState(false);
  const [activeDialogOpen, setActiveDialogOpen] = useState(false);
  const [actionLoading, setActionLoading] = useState(false);

  useEffect(() => {
    async function fetchData() {
      try {
        const [userResponse, meResponse] = await Promise.all([
          adminApi.users.get(userId),
          authApi.me(),
        ]);
        setUser(userResponse.data.user);
        setVpsList(userResponse.data.vps);
        setCurrentUserId(meResponse.data.id);
      } catch {
        toast({
          title: "Fout",
          description: "Kon gebruikersgegevens niet ophalen.",
          variant: "destructive",
        });
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, [userId, toast]);

  const isSelf = currentUserId === userId;

  async function handleToggleRole() {
    if (!user) return;
    setActionLoading(true);
    try {
      const newRole = user.role === "admin" ? "user" : "admin";
      const response = await adminApi.users.update(userId, { role: newRole });
      setUser(response.data);
      toast({
        title: "Rol gewijzigd",
        description: `Gebruiker is nu ${newRole}.`,
      });
    } catch {
      toast({
        title: "Fout",
        description: "Kon de rol niet wijzigen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
      setRoleDialogOpen(false);
    }
  }

  async function handleToggleActive() {
    if (!user) return;
    setActionLoading(true);
    try {
      const newActive = !user.is_active;
      const response = await adminApi.users.update(userId, { is_active: newActive });
      setUser(response.data);
      toast({
        title: newActive ? "Gebruiker geactiveerd" : "Gebruiker gedeactiveerd",
        description: newActive
          ? "De gebruiker kan nu weer inloggen."
          : "De gebruiker kan niet meer inloggen.",
      });
    } catch {
      toast({
        title: "Fout",
        description: "Kon de status niet wijzigen.",
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
      setActiveDialogOpen(false);
    }
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!user) {
    return (
      <div className="py-20 text-center text-muted-foreground">
        Gebruiker niet gevonden.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <Link href="/dashboard/admin/users">
        <Button variant="ghost" size="sm">
          <ArrowLeft className="mr-2 h-4 w-4" />
          Terug naar gebruikers
        </Button>
      </Link>

      <h1 className="text-3xl font-bold">Gebruiker: {user.name}</h1>

      <Card>
        <CardHeader>
          <CardTitle>Gebruikersgegevens</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <p className="text-sm text-muted-foreground">Naam</p>
              <p className="font-medium">{user.name}</p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">E-mail</p>
              <p className="font-medium">{user.email}</p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Rol</p>
              <Badge variant={user.role === "admin" ? "default" : "secondary"}>
                {user.role}
              </Badge>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Lid sinds</p>
              <p className="font-medium">{formatDate(user.date_joined)}</p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Status</p>
              <Badge variant={user.is_active ? "success" : "destructive"}>
                {user.is_active ? "Actief" : "Inactief"}
              </Badge>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Acties</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          {isSelf && (
            <div className="flex items-center gap-2 rounded-md border border-orange-200 bg-orange-50 p-3 text-sm text-orange-800 dark:border-orange-800 dark:bg-orange-950 dark:text-orange-200">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>
                Je kunt je eigen rol niet wijzigen en jezelf niet deactiveren.
              </span>
            </div>
          )}

          <div className="flex flex-wrap gap-3">
            <Button
              variant="outline"
              onClick={() => setRoleDialogOpen(true)}
              disabled={isSelf}
            >
              Rol wijzigen naar {user.role === "admin" ? "user" : "admin"}
            </Button>
            <Button
              variant={user.is_active ? "destructive" : "default"}
              onClick={() => setActiveDialogOpen(true)}
              disabled={isSelf}
            >
              {user.is_active ? "Deactiveren" : "Activeren"}
            </Button>
          </div>
        </CardContent>
      </Card>

      <Dialog open={roleDialogOpen} onOpenChange={setRoleDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Rol wijzigen</DialogTitle>
            <DialogDescription>
              Weet je zeker dat je de rol van {user.name} wilt wijzigen naar{" "}
              <strong>{user.role === "admin" ? "user" : "admin"}</strong>?
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setRoleDialogOpen(false)}
              disabled={actionLoading}
            >
              Annuleren
            </Button>
            <Button onClick={handleToggleRole} disabled={actionLoading}>
              {actionLoading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Bevestigen
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={activeDialogOpen} onOpenChange={setActiveDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {user.is_active ? "Gebruiker deactiveren" : "Gebruiker activeren"}
            </DialogTitle>
            <DialogDescription>
              Weet je zeker dat je {user.name} wilt{" "}
              {user.is_active ? "deactiveren" : "activeren"}?
              {user.is_active &&
                " De gebruiker kan dan niet meer inloggen."}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setActiveDialogOpen(false)}
              disabled={actionLoading}
            >
              Annuleren
            </Button>
            <Button
              variant={user.is_active ? "destructive" : "default"}
              onClick={handleToggleActive}
              disabled={actionLoading}
            >
              {actionLoading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Bevestigen
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Separator />

      <div className="space-y-4">
        <h2 className="text-xl font-semibold">
          VPS&apos;en van {user.name}
        </h2>

        {vpsList.length === 0 ? (
          <p className="text-muted-foreground">
            Deze gebruiker heeft geen VPS&apos;en.
          </p>
        ) : (
          <div className="rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>ID</TableHead>
                  <TableHead>Label</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>OS</TableHead>
                  <TableHead>IP</TableHead>
                  <TableHead>Acties</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {vpsList.map((vps) => (
                  <TableRow key={vps.id}>
                    <TableCell>{vps.id}</TableCell>
                    <TableCell className="font-medium">{vps.label}</TableCell>
                    <TableCell>
                      <StatusBadge status={vps.status} />
                    </TableCell>
                    <TableCell>{getOsLabel(vps.os)}</TableCell>
                    <TableCell>{vps.ip_address ?? "-"}</TableCell>
                    <TableCell>
                      <Link href={`/dashboard/admin/vps/${vps.id}`}>
                        <Button variant="outline" size="sm">
                          Bekijken
                        </Button>
                      </Link>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </div>
  );
}
