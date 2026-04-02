"use client";

import * as React from "react";
import Link from "next/link";
import { Server, Menu } from "lucide-react";
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
    <header className="sticky top-0 z-50 w-full border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
      <div className="container flex h-16 items-center">
        {/* Logo – links naar marketingsite */}
        <a href={WEBSITE_URL} className="mr-6 flex items-center gap-2">
          <Server className="h-5 w-5 text-primary" />
          <span className="text-lg font-display font-bold">
            <span className="gradient-text">Bunk</span>
            <span className="text-foreground">Hosting</span>
          </span>
        </a>

        {/* Desktop nav */}
        <nav className="hidden md:flex md:flex-1 md:items-center md:gap-6">
          <a
            href={WEBSITE_URL}
            className="text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
          >
            Home
          </a>
          <a
            href={`${WEBSITE_URL}/products`}
            className="text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
          >
            Producten
          </a>
        </nav>

        {/* Desktop auth buttons */}
        <div className="hidden md:flex md:items-center md:gap-2">
          <Button variant="outline" asChild>
            <Link href="/login">Inloggen</Link>
          </Button>
          <Button asChild>
            <Link href="/register">Registreren</Link>
          </Button>
        </div>

        {/* Mobile hamburger */}
        <div className="flex flex-1 justify-end md:hidden">
          <Sheet open={open} onOpenChange={setOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon">
                <Menu className="h-5 w-5" />
                <span className="sr-only">Menu openen</span>
              </Button>
            </SheetTrigger>
            <SheetContent side="right">
              <SheetTitle className="sr-only">Navigatie</SheetTitle>
              <div className="flex flex-col gap-4 mt-6">
                <a
                  href={WEBSITE_URL}
                  className="text-lg font-medium text-foreground"
                  onClick={() => setOpen(false)}
                >
                  Home
                </a>
                <a
                  href={`${WEBSITE_URL}/products`}
                  className="text-lg font-medium text-foreground"
                  onClick={() => setOpen(false)}
                >
                  Producten
                </a>
                <hr className="my-2" />
                <Button variant="outline" asChild>
                  <Link href="/login" onClick={() => setOpen(false)}>
                    Inloggen
                  </Link>
                </Button>
                <Button asChild>
                  <Link href="/register" onClick={() => setOpen(false)}>
                    Registreren
                  </Link>
                </Button>
              </div>
            </SheetContent>
          </Sheet>
        </div>
      </div>
    </header>
  );
}
