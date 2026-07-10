/**
 * API adapter — bridges the (unchanged) vps-frontend UI to the bunk-fleet
 * (Elixir) control-plane API.
 *
 * bunk-fleet uses bearer session tokens (Authorization: Bearer <token>) instead
 * of the old Django cookie+CSRF+JWT-refresh model, and returns its own JSON
 * shapes. This module is the single boundary that:
 *   - stores the bearer token client-side and attaches it to every request,
 *   - transforms bunk-fleet responses into the frontend's existing TS types,
 * so the React components stay byte-for-byte identical.
 */
import axios from "axios";
import type {
  User,
  Vps,
  VpsCredentials,
  VpsPackage,
  VpsStatus,
  OsChoice,
  BillingSettings,
  BillingOverview,
  Invoice,
  CompanySettings,
  AdminBillingOverview,
} from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_URL || "";

// Auth is carried by an HttpOnly `bunk_session` cookie set by the control plane on
// login/register and cleared on logout. The token is deliberately NOT kept in
// localStorage or any JS-readable place, so an XSS foothold can't exfiltrate a
// live session. Requests must be same-origin (the default: an empty API_URL routes
// through the Next `/api/v1` rewrite) for the browser to send the cookie;
// `withCredentials` below also covers a same-site cross-origin API host. The
// middleware gates /dashboard by reading the same cookie server-side.
function resetClientState(): void {
  // Drop cached catalog so a different user/session in the same tab refetches.
  packageCache = [];
  packagesPromise = null;
}

// Kept for API compatibility with pages that call it; bunk-fleet has no CSRF
// cookie to fetch (auth is a same-site HttpOnly cookie).
export async function ensureCsrfCookie(): Promise<void> {}

// Known bunk-fleet error codes -> friendly Dutch messages. Unknown codes fall
// back to the caller-supplied contextual message (never a raw code in the UI).
const ERROR_MESSAGES: Record<string, string> = {
  invalid_code: "De ingevoerde code klopt niet.",
  invalid_credentials: "Ongeldig e-mailadres of wachtwoord.",
  invalid_email_or_password: "Ongeldig e-mailadres of wachtwoord.",
  email_taken: "Dit e-mailadres is al in gebruik.",
  unauthorized: "Je bent niet (meer) ingelogd.",
  forbidden: "Je hebt geen toegang tot deze actie.",
  not_found: "Niet gevonden.",
  invalid_status_active: "De VPS draait al.",
  invalid_status_stopped: "De VPS is al gestopt.",
  invalid_status_queued: "De VPS wordt nog voorbereid.",
  invalid_status_provisioning: "De VPS wordt nog aangemaakt.",
};

/**
 * Turns an unknown thrown value (usually an Axios error) into a human-readable
 * Dutch message. Recognises bunk-fleet's error shapes — { error: "code" },
 * { detail: "..." }, and changeset-style { errors: { field: [msg] } } — and
 * otherwise returns the caller's contextual fallback. Never surfaces raw codes.
 */
export function parseApiError(err: unknown, fallback: string): string {
  if (axios.isAxiosError(err)) {
    const data = err.response?.data as Record<string, unknown> | string | undefined;
    if (data && typeof data === "object") {
      // Only surface a short, plain-text detail — never an HTML error page body.
      if (
        typeof data.detail === "string" &&
        data.detail.length > 0 &&
        data.detail.length < 200 &&
        !data.detail.includes("<")
      ) {
        return data.detail;
      }
      if (typeof data.error === "string") return ERROR_MESSAGES[data.error] ?? fallback;
      const errors = data.errors;
      if (errors && typeof errors === "object") {
        const first = Object.values(errors as Record<string, unknown>)[0];
        if (Array.isArray(first) && typeof first[0] === "string") return first[0];
        if (typeof first === "string") return first;
      }
    }
    if (err.code === "ERR_NETWORK") {
      return "Geen verbinding met de server. Probeer het later opnieuw.";
    }
  }
  return fallback;
}

const api = axios.create({
  baseURL: `${API_URL}/api/v1`,
  headers: { "Content-Type": "application/json" },
  // Send the HttpOnly session cookie with every request (needed for a same-site
  // cross-origin API host; a no-op for the same-origin default).
  withCredentials: true,
});

api.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error.response?.status;
    const url: string = error.config?.url || "";
    // Fail securely: a 401 outside the auth flow means the session is gone — drop
    // the token and send the user back to login.
    if (status === 401 && typeof window !== "undefined" && !url.includes("/auth/login") && !window.location.pathname.startsWith("/login")) {
      resetClientState();
      window.location.href = "/login";
    }
    return Promise.reject(error);
  }
);

// ── Transforms (bunk-fleet shapes → frontend types) ───────────────────
const STATUS_MAP: Record<string, VpsStatus> = {
  active: "ACTIVE",
  stopped: "STOPPED",
  paused: "STOPPED",
  queued: "PENDING",
  provisioning: "PROVISIONING",
  failed: "ERROR",
  deleting: "DELETING",
  deleted: "DELETED",
};

let packageCache: VpsPackage[] = [];
let packagesPromise: Promise<VpsPackage[]> | null = null;

// Memoize the in-flight request (not just the result) so concurrent first
// callers — e.g. /dashboard firing authApi.me() + vpsApi.list() together — share
// ONE GET /packages instead of each firing their own. Reset on logout.
async function ensurePackages(): Promise<VpsPackage[]> {
  if (packageCache.length > 0) return packageCache;
  if (!packagesPromise) {
    packagesPromise = api
      .get<{ count: number; results: VpsPackage[] }>("/packages")
      .then((res) => {
        packageCache = res.data.results;
        return packageCache;
      })
      .catch((err) => {
        packagesPromise = null; // allow a retry on the next call
        throw err;
      });
  }
  return packagesPromise;
}

function packageForSpecs(vcpu: number, ramMb: number, diskGb: number): VpsPackage {
  // Exact match on all three dimensions — rounding RAM or ignoring disk could
  // surface the wrong package (and wrong price) for non-catalog specs.
  const match = packageCache.find(
    (p) => p.cpu_cores === vcpu && p.ram_gb * 1024 === ramMb && p.disk_gb === diskGb,
  );
  if (match) return match;
  return {
    id: 0,
    name: "Custom",
    cpu_cores: vcpu,
    ram_gb: Math.round(ramMb / 1024),
    disk_gb: diskGb,
    bandwidth_tb: 1,
    price_monthly: "0.00",
    description: "",
  };
}

interface BunkVps {
  id: string;
  name: string;
  status: string;
  ip_address: string | null;
  vcpu: number;
  ram_mb: number;
  disk_gb: number;
  region?: string | null;
  provider_vm_id?: string | null;
  inserted_at: string;
}

function transformVps(v: BunkVps): Vps {
  return {
    id: v.id,
    label: v.name,
    package: packageForSpecs(v.vcpu, v.ram_mb, v.disk_gb),
    os: "ubuntu-22.04",
    status: STATUS_MAP[v.status] ?? "PENDING",
    ip_address: v.ip_address,
    hostname: null,
    ssh_port: 22,
    ssh_username: "root",
    vcenter_vm_id: v.provider_vm_id ?? null,
    created_at: v.inserted_at,
    updated_at: v.inserted_at,
    owner: "",
    owner_email: null,
  };
}

interface BunkUser {
  id: string;
  email: string;
  name: string | null;
  role: "user" | "admin" | "operator";
  inserted_at?: string;
  totp_enabled?: boolean;
  confirmed_at?: string | null;
}

function transformUser(u: BunkUser): User {
  return {
    id: u.id,
    email: u.email,
    name: u.name || u.email,
    role: u.role === "operator" ? "user" : u.role,
    date_joined: u.inserted_at || "",
    is_active: true,
    totp_enabled: Boolean(u.totp_enabled),
  };
}

// ── Auth ──────────────────────────────────────────────────────────────
export const authApi = {
  register: async (name: string, email: string, password: string, _passwordConfirm: string, captcha?: string) => {
    // The control plane sets the HttpOnly session cookie on this response; there
    // is no token to store client-side.
    await api.post("/auth/register", {
      name,
      email,
      password,
      // Sent to the server for server-side Turnstile verification (enforced when
      // the backend has TURNSTILE_SECRET_KEY configured).
      ...(captcha ? { turnstile_token: captcha } : {}),
    });
    return { data: { detail: "ok" } };
  },

  // bunk-fleet login is single-step (password → token); the frontend's optional
  // OTP/TOTP steps simply never trigger because no *_required flag is returned.
  login: async (email: string, password: string, captcha?: string, code?: string) => {
    const res = await api.post<{ user?: BunkUser; token?: string; totp_required?: boolean }>(
      "/auth/login",
      {
        email,
        password,
        // Sent for server-side Turnstile verification (enforced when the backend
        // has TURNSTILE_SECRET_KEY configured) — same contract as register.
        ...(captcha ? { turnstile_token: captcha } : {}),
        ...(code ? { code } : {}),
      },
    );
    // 2FA gate: the backend returns { totp_required: true } and does NOT set the
    // session cookie until a valid TOTP code is supplied.
    if (res.data.totp_required) {
      return { data: { totp_required: true } as { otp_required?: boolean; totp_required?: boolean; verification_required?: boolean } };
    }
    // On success the control plane sets the HttpOnly session cookie on this response.
    return { data: {} as { otp_required?: boolean; totp_required?: boolean; verification_required?: boolean } };
  },



  logout: async () => {
    try {
      // The control plane clears the HttpOnly session cookie on this response.
      await api.delete("/auth/logout");
    } finally {
      resetClientState();
    }
    return { data: {} };
  },

  me: async () => {
    const res = await api.get<{ user: BunkUser }>("/auth/me");
    return { data: transformUser(res.data.user) };
  },

  // bunk-fleet has no email-verification / password-reset endpoints yet, so these
  // REJECT instead of faking success — the UI must never tell a user their
  // password changed or their email was verified when nothing happened.
  verifyEmail: (_token: string) =>
    Promise.reject(new Error("E-mailverificatie is nog niet beschikbaar.")),
  // Safe to resolve regardless: this never claims a completed change and the
  // anti-enumeration contract is "if the address exists, a link was sent".
  requestPasswordReset: (_email: string) => Promise.resolve({ data: { detail: "ok" } }),
  confirmPasswordReset: (_token: string, _password: string, _passwordConfirm: string) =>
    Promise.reject(new Error("Wachtwoord opnieuw instellen is nog niet beschikbaar.")),

  totp: {
    setup: () => api.get<{ secret: string; qr_data_url: string }>("/auth/totp/setup"),
    confirm: (code: string) => api.post<{ detail: string }>("/auth/totp/setup", { code }),
    disable: (code: string) => api.delete<{ detail: string }>("/auth/totp/disable", { data: { code } }),
  },
};

// ── Packages ──────────────────────────────────────────────────────────
export const packagesApi = {
  list: async () => {
    const packages = await ensurePackages();
    return { data: { count: packages.length, results: packages } };
  },
};

// ── VPS ───────────────────────────────────────────────────────────────
export const vpsApi = {
  list: async () => {
    // Package catalog is cosmetic here (spec→name/price mapping with a "Custom"
    // fallback) — a broken /packages endpoint must not take down the VPS list.
    await ensurePackages().catch(() => []);
    const res = await api.get<{ vpses: BunkVps[] }>("/vpses");
    const results = res.data.vpses.map(transformVps);
    return { data: { count: results.length, results } };
  },

  get: async (id: string) => {
    await ensurePackages().catch(() => []);
    const res = await api.get<{ vps: BunkVps }>(`/vpses/${id}`);
    return { data: transformVps(res.data.vps) };
  },

  create: async (data: { label?: string; package_id: number; os: OsChoice }) => {
    const packages = await ensurePackages();
    const pkg = packages.find((p) => p.id === data.package_id);
    if (!pkg) throw new Error("Onbekend pakket.");
    const res = await api.post<{ vps: BunkVps }>("/vpses", {
      name: data.label || `vps-${Date.now()}`,
      vcpu: pkg.cpu_cores,
      ram_mb: pkg.ram_gb * 1024,
      disk_gb: pkg.disk_gb,
      region_code: "nl-1",
    });
    return { data: transformVps(res.data.vps) };
  },

  credentials: async (id: string): Promise<{ data: VpsCredentials }> => {
    const res = await api.get<{ vps: BunkVps }>(`/vpses/${id}`);
    return {
      data: {
        ip_address: res.data.vps.ip_address,
        ssh_port: 22,
        ssh_username: "root",
        sudo_password: null,
      },
    };
  },

  delete: (id: string) => api.delete(`/vpses/${id}`),
  start: (id: string) => api.post<{ detail: string }>(`/vpses/${id}/start`),
  stop: (id: string) => api.post<{ detail: string }>(`/vpses/${id}/stop`),
  // Mint a single-use console ticket (the WS handshake can't carry the bearer).
  consoleTicket: async (id: string): Promise<{ ticket: string }> => {
    const res = await api.post<{ ticket: string }>(`/vpses/${id}/console-ticket`);
    return res.data;
  },
};


// ── Admin (old-stack surface — adapted later; endpoints may 404 on bunk-fleet) ──
// ── Admin panel (session-authenticated, role :admin) ──────────────────────
export interface AdminStats {
  users: { total: number; user: number; operator: number; admin: number };
  vpses: { total: number; active: number; stopped: number; provisioning: number; failed: number };
  nodes: { total: number; online: number; datacenter: number; community: number };
  credit_outstanding_cents: number;
}
export interface AdminUser {
  id: string;
  name: string;
  email: string;
  role: "user" | "operator" | "admin";
  confirmed: boolean;
  two_factor: boolean;
  inserted_at: string;
  vps_count: number;
  balance_cents: number;
}
export interface AdminVps {
  id: string;
  name: string;
  status: string;
  tier: string;
  owner_email: string | null;
  node: string | null;
  region: string | null;
  vcpu: number;
  ram_mb: number;
  disk_gb: number;
  ip_address: string | null;
  inserted_at: string;
}
export interface AdminNode {
  id: string;
  name: string;
  tier: string;
  status: string;
  owner_email: string | null;
  region: string | null;
  total_vcpu: number;
  total_ram_mb: number;
  total_disk_gb: number;
  available_vcpu: number;
  available_ram_mb: number;
  available_disk_gb: number;
  last_heartbeat_at: string | null;
}

// NOTE: paths are /beheer/* (not /admin/*) — Cloudflare's WAF blocks "/admin"
// URLs with a challenge page before they reach the origin.
export const adminApi = {
  stats: async (): Promise<AdminStats> => (await api.get<AdminStats>("/beheer/stats")).data,
  users: async (): Promise<AdminUser[]> =>
    (await api.get<{ users: AdminUser[] }>("/beheer/users")).data.users,
  setRole: (id: string, role: "user" | "operator" | "admin") =>
    api.patch<{ id: string; role: string }>(`/beheer/users/${id}`, { role }),
  addCredit: (id: string, amountCents: number) =>
    api.post<{ id: string; balance_cents: number }>(`/beheer/users/${id}/credit`, {
      amount_cents: amountCents,
    }),
  vpses: async (): Promise<AdminVps[]> =>
    (await api.get<{ vpses: AdminVps[] }>("/beheer/vpses")).data.vpses,
  vpsStart: (id: string) => api.post(`/beheer/vpses/${id}/start`),
  vpsStop: (id: string) => api.post(`/beheer/vpses/${id}/stop`),
  vpsDelete: (id: string) => api.delete(`/beheer/vpses/${id}`),
  nodes: async (): Promise<AdminNode[]> =>
    (await api.get<{ nodes: AdminNode[] }>("/beheer/nodes")).data.nodes,
  nodeDelete: (id: string) => api.delete(`/beheer/nodes/${id}`),
};

// Billing — adapted to bunk-fleet. The overview is derived live from the
// customer's active VPSes and the package catalog (bunk-fleet bills per running
// VPS). bunk-fleet has no invoicing engine yet, so the invoice list is honestly
// empty rather than fabricated; the UI then shows its "no invoices" state.
export interface WalletEntry {
  amount_cents: number;
  kind: string;
  description: string | null;
  inserted_at: string;
}

export interface WalletTopup {
  amount_cents: number;
  status: "pending" | "paid" | "cancelled";
  reference: string;
  inserted_at: string;
}

export interface Wallet {
  balance_cents: number;
  entries: WalletEntry[];
  topups: WalletTopup[];
}

export interface UsageVps {
  vps_id: string;
  name: string;
  seconds: number;
  cost: string;
}

export interface UsageSummary {
  from: string;
  to: string;
  total_seconds: number;
  total_cost: string;
  vpses: UsageVps[];
}

export const billingApi = {
  // The real prepaid-wallet surface (bunk-fleet's actual customer billing model).
  wallet: async (): Promise<{ data: Wallet }> => {
    const res = await api.get<Wallet>("/billing/wallet");
    return { data: res.data };
  },

  usage: async (): Promise<{ data: UsageSummary }> => {
    const res = await api.get<UsageSummary>("/billing/usage");
    return { data: res.data };
  },

  // Start a Mollie top-up; returns the hosted checkout URL to redirect the user to.
  topup: async (
    amountCents: number
  ): Promise<{ checkout_url: string; payment_id: string }> => {
    const res = await api.post<{ checkout_url: string; payment_id: string }>(
      "/billing/topup",
      { amount_cents: amountCents }
    );
    return res.data;
  },

  overview: async (): Promise<{ data: BillingOverview }> => {
    const res = await vpsApi.list();
    const active = res.data.results.filter(
      (v) => v.status === "ACTIVE" || v.status === "STOPPED"
    );
    const monthly = active.reduce(
      (sum, v) => sum + parseFloat(v.package?.price_monthly ?? "0"),
      0
    );
    const now = new Date();
    const next = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    return {
      data: {
        open_amount: "0.00",
        open_invoice_count: 0,
        monthly_cost: monthly.toFixed(2),
        active_subscriptions: active.length,
        next_invoice_date: next.toISOString().slice(0, 10),
      },
    };
  },
  settings: {
    get: async (): Promise<{ data: BillingSettings }> => ({
      data: { billing_cycle: "monthly", billing_email: "" },
    }),
    update: async (
      _data: Partial<BillingSettings>
    ): Promise<{ data: BillingSettings }> => {
      // bunk-fleet has no billing-settings endpoint yet — don't echo the input
      // back as if it persisted (the UI would claim a save that never happened).
      throw new Error("Factuurinstellingen zijn nog niet beschikbaar.");
    },
  },
  invoices: {
    list: async (
      _params?: { status?: string }
    ): Promise<{ data: { count: number; results: Invoice[] } }> => ({
      data: { count: 0, results: [] },
    }),
    get: async (_id: string | number): Promise<{ data: Invoice }> => {
      throw new Error("Facturen zijn nog niet beschikbaar.");
    },
    pay: async (_id: string | number) => {
      throw new Error("Facturen zijn nog niet beschikbaar.");
    },
    downloadUrl: (_id: string | number) => "#",
  },
};

// ── Host onboarding (federation: "bring your own hardware") ──────────────
// A plain user opts in via hostApi.activate() (promotes them to operator on the
// control plane); thereafter they mint enroll tokens and see their own nodes +
// earnings. The node/token/earnings endpoints live under /operator/* and are
// role-gated, so they only work AFTER activation.
export interface HostNode {
  id: string;
  name: string;
  status: string;
  tier: string;
  // Datacenter nodes are shared company clusters (no earnings); community nodes
  // belong to the operator and accrue payout.
  shared: boolean;
  hypervisor: string;
  region: string | null;
  total_vcpu: number;
  total_ram_mb: number;
  total_disk_gb: number;
  available_vcpu: number;
  available_ram_mb: number;
  available_disk_gb: number;
  last_heartbeat_at: string | null;
}
export interface HostRegion {
  id: string;
  code: string;
  name: string;
}
export interface EnrollTokenResult {
  enroll_token: string;
  expires_at: string;
  region: string;
  tier: string;
  install: string;
}
export interface HostEarnings {
  from: string;
  to: string;
  amount: string;
  seconds: number;
  records: number;
}

export const hostApi = {
  status: async (): Promise<{ is_host: boolean; is_admin?: boolean; role: string }> => {
    const res = await api.get<{ is_host: boolean; is_admin?: boolean; role: string }>(
      "/host/status"
    );
    return res.data;
  },
  activate: async (): Promise<{ is_host: boolean; role: string }> => {
    const res = await api.post<{ is_host: boolean; role: string }>("/host/activate", {});
    return res.data;
  },
  regions: async (): Promise<HostRegion[]> => {
    const res = await api.get<{ regions: HostRegion[] }>("/host/regions");
    return res.data.regions;
  },
  createEnrollToken: async (
    regionCode: string,
    tier: "community" | "datacenter" = "community",
  ): Promise<EnrollTokenResult> => {
    const res = await api.post<EnrollTokenResult>("/operator/enroll-tokens", {
      region_code: regionCode,
      tier,
    });
    return res.data;
  },
  nodes: async (): Promise<HostNode[]> => {
    const res = await api.get<{ nodes: HostNode[] }>("/operator/nodes");
    return res.data.nodes;
  },
  earnings: async (): Promise<HostEarnings> => {
    const res = await api.get<HostEarnings>("/operator/earnings");
    return res.data;
  },
};

export const adminBillingApi = {
  overview: () => api.get<AdminBillingOverview>("/beheer/billing/overview"),
  company: {
    get: () => api.get<CompanySettings>("/beheer/billing/company"),
    update: (data: Partial<CompanySettings>) =>
      api.post<CompanySettings>("/beheer/billing/company", data),
  },
  invoices: {
    list: (params?: { status?: string; user_id?: string }) =>
      api.get<{ count: number; results: Invoice[] }>("/beheer/billing/invoices", { params }),
    get: (id: string) => api.get<Invoice>(`/beheer/billing/invoices/${id}`),
    update: (id: string, data: { status: string }) =>
      api.patch<Invoice>(`/beheer/billing/invoices/${id}`, data),
  },
};
