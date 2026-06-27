"use client";

import * as React from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import {
  Sheet,
  SheetContent,
  SheetTrigger,
  SheetTitle,
} from "@/components/ui/sheet";

const WEBSITE_URL = process.env.NEXT_PUBLIC_WEBSITE_URL || "http://localhost:3000";

export function Navbar() {
  const [open, setOpen] = React.useState(false);

  return (
    <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10 transition-all duration-300">
      <div className="max-w-7xl mx-auto flex justify-between items-center px-6 lg:px-8 h-16 w-full">

        {/* Links: logo + desktop nav */}
        <div className="flex items-center gap-6">
          <a href={WEBSITE_URL} className="flex items-center gap-3">
            <span
              className="material-symbols-outlined text-accent"
              style={{ fontVariationSettings: "'FILL' 1" }}
            >
              dns
            </span>
            <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
              BUNK HOSTING
            </span>
          </a>
          <nav className="hidden md:flex items-center gap-6">
            <a
              href={WEBSITE_URL}
              className="text-sm font-semibold text-foreground hover:text-accent transition-colors"
            >
              Home
            </a>
            <a
              href={`${WEBSITE_URL}/#pakketten`}
              className="text-sm font-semibold text-on-surface-variant hover:text-foreground transition-colors"
            >
              VPS
            </a>
            <a
              href={`${WEBSITE_URL}/#features`}
              className="text-sm font-semibold text-on-surface-variant hover:text-foreground transition-colors"
            >
              Netwerk
            </a>
          </nav>
        </div>

        {/* Rechts: auth + mobile menu */}
        <div className="flex items-center gap-4">
          <Link
            href="/login"
            className="hidden md:block text-sm font-semibold text-on-surface-variant hover:text-accent transition-colors"
          >
            Client Area
          </Link>
          <Link href="/login">
            <span
              className="hidden md:block material-symbols-outlined text-on-surface-variant hover:text-accent cursor-pointer transition-colors"
              style={{ textDecoration: "none" }}
            >
              account_circle
            </span>
          </Link>

          {/* Mobile hamburger */}
          <Sheet open={open} onOpenChange={setOpen}>
            <SheetTrigger asChild>
              <span
                className="material-symbols-outlined md:hidden text-accent cursor-pointer"
              >
                menu
              </span>
            </SheetTrigger>
            <SheetContent side="right" className="bg-background/95 backdrop-blur-xl border-outline-variant/10">
              <SheetTitle className="sr-only">Navigatie</SheetTitle>
              <div className="flex flex-col gap-4 mt-6">
                <a href={WEBSITE_URL} className="text-lg font-semibold text-foreground" onClick={() => setOpen(false)}>Home</a>
                <a href={`${WEBSITE_URL}/#pakketten`} className="text-lg font-semibold text-on-surface-variant" onClick={() => setOpen(false)}>VPS</a>
                <a href={`${WEBSITE_URL}/#features`} className="text-lg font-semibold text-on-surface-variant" onClick={() => setOpen(false)}>Netwerk</a>
                <div className="divider-glow my-2" />
                <Button variant="outline" asChild>
                  <Link href="/login" onClick={() => setOpen(false)}>Inloggen</Link>
                </Button>
                <Button asChild>
                  <Link href="/register" onClick={() => setOpen(false)}>Registreren</Link>
                </Button>
              </div>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </header>
  );
}
