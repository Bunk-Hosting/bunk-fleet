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
