"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter, usePathname } from "next/navigation";
import {
  LayoutDashboard,
  Network,
  PlusCircle,
  RefreshCw,
  Shield,
  Users,
  Server,
  ServerCog,
  FileText,
  LogOut,
  Menu,
  Ticket,
  CreditCard,
  Receipt,
  Settings,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import {
  Sheet,
  SheetContent,
  SheetTrigger,
  SheetTitle,
} from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { authApi } from "@/lib/api";
import type { User } from "@/lib/types";

interface SidebarProps {
  user: User;
}

interface NavItem {
  label: string;
  href: string;
  icon: React.ElementType;
}

const mainNavItems: NavItem[] = [
  { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
  { label: "Mijn VPS'en", href: "/dashboard/vps", icon: Server },
  { label: "Nieuwe VPS", href: "/dashboard/vps/new", icon: PlusCircle },
];

const billingNavItems: NavItem[] = [
  { label: "Finance", href: "/dashboard/billing", icon: CreditCard },
  { label: "Facturen", href: "/dashboard/billing/invoices", icon: Receipt },
];

const adminNavItems: NavItem[] = [
  { label: "Admin", href: "/dashboard/admin", icon: Shield },
  { label: "Gebruikers", href: "/dashboard/admin/users", icon: Users },
  { label: "VPS Beheer", href: "/dashboard/admin/vps", icon: ServerCog },
  { label: "Netwerk", href: "/dashboard/admin/network", icon: Network },
  { label: "Auditlogs", href: "/dashboard/admin/logs", icon: FileText },
  { label: "Reconciliatie", href: "/dashboard/admin/reconcile", icon: RefreshCw },
  { label: "Invite codes", href: "/dashboard/admin/invite-codes", icon: Ticket },
];

const adminSettingsItem: NavItem = {
  label: "Instellingen",
  href: "/dashboard/admin/settings",
  icon: Settings,
};

const allNavItems = [
  ...mainNavItems,
  ...billingNavItems,
  ...adminNavItems,
  adminSettingsItem,
];

function isActive(itemHref: string, pathname: string): boolean {
  if (pathname === itemHref) return true;
  if (!pathname.startsWith(itemHref + "/")) return false;
  return !allNavItems.some(
    (other) =>
      other.href !== itemHref &&
      other.href.length > itemHref.length &&
      pathname.startsWith(other.href)
  );
}

function NavLink({ item, pathname }: { item: NavItem; pathname: string }) {
  const active = isActive(item.href, pathname);

  return (
    <Link
      href={item.href}
      className={cn(
        "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        active
          ? "bg-primary text-primary-foreground"
          : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
      )}
    >
      <item.icon className="h-4 w-4" />
      {item.label}
    </Link>
  );
}

function SidebarContent({ user }: SidebarProps) {
  const router = useRouter();
  const pathname = usePathname();

  const handleLogout = async () => {
    try {
      await authApi.logout();
    } catch {
      // ignore logout errors
    }
    router.push("/login");
  };

  return (
    <div className="flex h-full flex-col">
      {/* Logo */}
      <div className="px-4 py-6">
        <Link href="/dashboard" className="flex items-center gap-3">
          <span
            className="material-symbols-outlined text-accent"
            style={{ fontVariationSettings: "'FILL' 1" }}
          >
            dns
          </span>
          <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
            BUNK HOSTING
          </span>
        </Link>
      </div>

      <Separator />

      {/* Scrollable nav area */}
      <nav className="flex-1 overflow-y-auto space-y-1 px-3 py-4">
        <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Menu
        </p>
        {mainNavItems.map((item) => (
          <NavLink key={item.href} item={item} pathname={pathname} />
        ))}

        <Separator className="my-4" />
        <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Finance
        </p>
        {billingNavItems.map((item) => (
          <NavLink key={item.href} item={item} pathname={pathname} />
        ))}

        {user.role === "admin" && (
          <>
            <Separator className="my-4" />
            <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Beheer
            </p>
            {adminNavItems.map((item) => (
              <NavLink key={item.href} item={item} pathname={pathname} />
            ))}
          </>
        )}
      </nav>

      <Separator />

      {/* Bodem: instellingen (admin) + uitloggen */}
      <div className="px-3 py-4 space-y-1">
        {user.role === "admin" && (
          <NavLink item={adminSettingsItem} pathname={pathname} />
        )}
        <div className="px-3 pt-2">
          <p className="text-sm font-medium">{user.name}</p>
          <p className="text-xs text-muted-foreground">{user.email}</p>
        </div>
        <Button
          variant="ghost"
          className="w-full justify-start gap-3 text-muted-foreground hover:text-foreground"
          onClick={handleLogout}
        >
          <LogOut className="h-4 w-4" />
          Uitloggen
        </Button>
      </div>
    </div>
  );
}

export function Sidebar({ user }: SidebarProps) {
  const [open, setOpen] = useState(false);

  return (
    <>
      {/* Desktop sidebar */}
      <aside className="hidden md:flex md:w-64 md:flex-col md:fixed md:inset-y-0 border-r bg-card z-20">
        <SidebarContent user={user} />
      </aside>

      {/* Mobile hamburger button */}
      <div className="sticky top-0 z-40 flex items-center gap-4 border-b bg-background px-4 py-3 md:hidden">
        <Sheet open={open} onOpenChange={setOpen}>
          <SheetTrigger asChild>
            <Button variant="ghost" size="icon">
              <Menu className="h-5 w-5" />
              <span className="sr-only">Menu openen</span>
            </Button>
          </SheetTrigger>
          <SheetContent side="left" className="w-64 p-0">
            <SheetTitle className="sr-only">Navigatie</SheetTitle>
            <div onClick={() => setOpen(false)}>
              <SidebarContent user={user} />
            </div>
          </SheetContent>
        </Sheet>
        <Link href="/dashboard" className="flex items-center gap-3">
          <span
            className="material-symbols-outlined text-accent"
            style={{ fontVariationSettings: "'FILL' 1" }}
          >
            dns
          </span>
          <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
            BUNK HOSTING
          </span>
        </Link>
      </div>
    </>
  );
}
