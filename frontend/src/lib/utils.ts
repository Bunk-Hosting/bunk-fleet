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

export function formatEuro(value: number | string): string {
  return `€ ${Number(value).toFixed(2).replace(".", ",")}`;
}

/**
 * Boven dit bedrag is het tegoed geen bedrag meer maar een besluit: dit account
 * hoeft niet op zijn saldo te letten. Negen mille en wat op het scherm nodigt
 * uit tot rekenen dat nergens over gaat, en het ziet eruit als een fout.
 *
 * Alleen een label. Het grootboek houdt het echte getal bij, elke afschrijving
 * gaat gewoon door, en zakt het saldo hieronder dan staat het bedrag er weer.
 */
export const ONBEPERKT_TEGOED_CENTEN = 999_900;

export function isOnbeperktTegoed(cents: number): boolean {
  return cents > ONBEPERKT_TEGOED_CENTEN;
}

/** Een saldo zoals de gebruiker het ziet: een bedrag, of "Unlimited". */
export function formatBalance(cents: number): string {
  return isOnbeperktTegoed(cents) ? "Unlimited" : formatEuro(cents / 100);
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

// De netwerksnelheid van een pakket, zoals een klant hem hoort te lezen.
//
// "tot", want het is een bovengrens die de hypervisor afdwingt op de
// netwerkkaart van de gast en geen gegarandeerde doorvoer: de uplink is
// gedeeld. Vanaf 1000 Mbit in Gbit, omdat niemand "1000 Mbit" zegt.
export function formatBandbreedte(mbit: number | null | undefined): string {
  if (!mbit || mbit <= 0) return "—";
  if (mbit % 1000 === 0) return `tot ${mbit / 1000} Gbit/s`;
  return `tot ${mbit} Mbit/s`;
}
