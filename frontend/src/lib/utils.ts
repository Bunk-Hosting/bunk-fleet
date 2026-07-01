import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatDate(dateString: string): string {
  const date = new Date(dateString);
  return date.toLocaleDateString("nl-NL", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export function formatDateTime(dateString: string): string {
  const date = new Date(dateString);
  return date.toLocaleDateString("nl-NL", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Single euro formatter; formatPrice kept as an alias for its existing callers.
export function formatPrice(price: number | string): string {
  return formatEuro(price);
}

export function formatEuro(value: number | string): string {
  return `€ ${Number(value).toFixed(2).replace(".", ",")}`;
}

export function formatDateLong(dateStr: string | null | undefined): string {
  if (!dateStr) return "—";
  return new Date(dateStr).toLocaleDateString("nl-NL", {
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

// Client-side CSV export (replaces the vulnerable `xlsx` dep). Uses `;` (nl-NL
// Excel convention) and a UTF-8 BOM so accents render correctly in Excel.
export function downloadCsv(
  filename: string,
  rows: Record<string, string | number>[]
): void {
  if (rows.length === 0) return;
  const headers = Object.keys(rows[0]);
  const escape = (v: string | number) => {
    const s = String(v ?? "");
    return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const csv = [
    headers.join(";"),
    ...rows.map((r) => headers.map((h) => escape(r[h])).join(";")),
  ].join("\r\n");

  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export function getOsLabel(os: string): string {
  const labels: Record<string, string> = {
    "ubuntu-22.04": "Ubuntu 22.04 LTS",
    "ubuntu-20.04": "Ubuntu 20.04 LTS",
    "debian-12": "Debian 12",
    "debian-11": "Debian 11",
    "centos-9": "CentOS 9",
    "alpine-3.19": "Alpine 3.19",
  };
  return labels[os] || os;
}
