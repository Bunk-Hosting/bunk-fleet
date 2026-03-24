import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";
import { Toaster } from "@/components/ui/toaster";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Bunk Hosting - VPS Hosting",
  description:
    "Betrouwbare en snelle VPS hosting uit Nederland. Krachtige virtuele servers met NVMe SSD opslag en een uitstekend Nederlands netwerk.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="nl">
      <body className={inter.className}>
        {children}
        <Toaster />
      </body>
    </html>
  );
}
