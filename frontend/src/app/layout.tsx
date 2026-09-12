import type { Metadata } from "next";
import { Inter, Manrope } from "next/font/google";
import "./globals.css";
import { Toaster } from "@/components/ui/toaster";
import { ObservabilityInit } from "@/components/observability-init";

const inter = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-inter",
});
const manrope = Manrope({
  subsets: ["latin"],
  weight: ["400", "600", "700", "800"],
  variable: "--font-manrope",
});

// Every page renders per request. The CSP nonce is minted in middleware, so a
// page prerendered at build time would ship a nonce that no live response
// carries — its scripts would be blocked and the page would come up blank. This
// app is a dashboard behind a session cookie; there was nothing to cache anyway.
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Bunk Hosting | VPS Beheer",
  description: "Beheer je virtuele servers via het Bunk Hosting dashboard.",
  icons: { icon: "/favicon.svg" },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="nl" className="dark">
      <body className={`${inter.variable} ${manrope.variable} font-sans`}>
        <ObservabilityInit />
        {children}
        <Toaster />
      </body>
    </html>
  );
}
