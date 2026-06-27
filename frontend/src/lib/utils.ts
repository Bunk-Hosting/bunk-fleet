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

export function formatPrice(price: number | string): string {
  return `€${Number(price).toFixed(2).replace(".", ",")}`;
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
