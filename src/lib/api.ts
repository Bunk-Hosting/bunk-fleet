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
  AdminStats,
  AdminNetworkResponse,
  AuditLog,
  IPAddressStatus,
  PaginatedResponse,
  ReconcileStatusResponse,
  BillingSettings,
  BillingOverview,
  Invoice,
  CompanySettings,
  AdminBillingOverview,
} from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_URL || "";
const TOKEN_KEY = "bunk_token";

function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(TOKEN_KEY);
}
function setToken(token: string): void {
  if (typeof window !== "undefined") window.localStorage.setItem(TOKEN_KEY, token);
}
function clearToken(): void {
  if (typeof window !== "undefined") window.localStorage.removeItem(TOKEN_KEY);
}

// Kept for API compatibility with pages that called it; bunk-fleet uses bearer
// tokens, so there is no CSRF cookie to fetch.
export async function ensureCsrfCookie(): Promise<void> {}

const api = axios.create({
  baseURL: `${API_URL}/api/v1`,
  headers: { "Content-Type": "application/json" },
});

api.interceptors.request.use((config) => {
  const token = getToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

api.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error.response?.status;
    const url: string = error.config?.url || "";
    // Fail securely: a 401 outside the auth flow means the session is gone — drop
    // the token and send the user back to login.
    if (status === 401 && typeof window !== "undefined" && !url.includes("/auth/login") && !window.location.pathname.startsWith("/login")) {
      clearToken();
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

async function ensurePackages(): Promise<VpsPackage[]> {
  if (packageCache.length === 0) {
    const res = await api.get<{ count: number; results: VpsPackage[] }>("/packages");
    packageCache = res.data.results;
  }
  return packageCache;
}

function packageForSpecs(vcpu: number, ramMb: number, diskGb: number): VpsPackage {
  const ramGb = Math.round(ramMb / 1024);
  const match = packageCache.find((p) => p.cpu_cores === vcpu && p.ram_gb === ramGb);
  if (match) return match;
  return {
    id: 0,
    name: "Custom",
    cpu_cores: vcpu,
    ram_gb: ramGb,
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
  totp_confirmed_at?: string | null;
}

function transformUser(u: BunkUser): User {
  return {
    id: u.id,
    email: u.email,
    name: u.name || u.email,
    role: u.role === "operator" ? "user" : u.role,
    date_joined: u.inserted_at || "",
    is_active: true,
    totp_enabled: Boolean(u.totp_confirmed_at),
  };
}

// ── Auth ──────────────────────────────────────────────────────────────
export const authApi = {
  register: async (name: string, email: string, password: string, _passwordConfirm: string) => {
    const res = await api.post<{ user: BunkUser; token: string }>("/auth/register", { name, email, password });
    setToken(res.data.token);
    return { data: { detail: "ok" } };
  },

  // bunk-fleet login is single-step (password → token); the frontend's optional
  // OTP/TOTP steps simply never trigger because no *_required flag is returned.
  login: async (email: string, password: string) => {
    const res = await api.post<{ user: BunkUser; token: string }>("/auth/login", { email, password });
    setToken(res.data.token);
    return { data: {} as { otp_required?: boolean; totp_required?: boolean; verification_required?: boolean } };
  },

  loginOtp: async (email: string, _code: string) => {
    const res = await api.get<{ user: BunkUser }>("/auth/me");
    return { data: { user: transformUser(res.data.user), message: "ok" } };
  },

  loginTotp: async (email: string, _code: string) => {
    const res = await api.get<{ user: BunkUser }>("/auth/me");
    return { data: { user: transformUser(res.data.user), message: "ok" } };
  },

  logout: async () => {
    try {
      await api.delete("/auth/logout");
    } finally {
      clearToken();
    }
    return { data: {} };
  },

  me: async () => {
    const res = await api.get<{ user: BunkUser }>("/auth/me");
    return { data: transformUser(res.data.user) };
  },

  verifyEmail: (_token: string) => Promise.resolve({ data: { detail: "ok" } }),
  resendVerification: () => Promise.resolve({ data: { detail: "ok" } }),
  requestPasswordReset: (_email: string) => Promise.resolve({ data: { detail: "ok" } }),
  confirmPasswordReset: (_token: string, _password: string, _passwordConfirm: string) =>
    Promise.resolve({ data: { detail: "ok" } }),

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
    await ensurePackages();
    const res = await api.get<{ vpses: BunkVps[] }>("/vpses");
    const results = res.data.vpses.map(transformVps);
    return { data: { count: results.length, results } };
  },

  get: async (id: string) => {
    await ensurePackages();
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
};


// ── Admin (old-stack surface — adapted later; endpoints may 404 on bunk-fleet) ──
export const adminApi = {
  stats: () => api.get<AdminStats>("/beheer/stats"),
  users: {
    list: () => api.get<{ count: number; results: User[] }>("/beheer/users"),
    get: (id: string) => api.get<{ user: User; vps: Vps[] }>(`/beheer/users/${id}`),
    update: (id: string, data: { role?: "user" | "admin"; is_active?: boolean }) =>
      api.patch<User>(`/beheer/users/${id}`, data),
  },
  vps: {
    list: (params?: { status?: VpsStatus; owner_id?: string; os?: OsChoice }) =>
      api.get<{ count: number; results: Vps[] }>("/beheer/vps", { params }),
    get: (id: string) => api.get<Vps>(`/beheer/vps/${id}`),
    create: (data: { label?: string; package_id: number; os: OsChoice; owner_id: string }) =>
      api.post<Vps>("/beheer/vps", data),
    update: (id: string, data: { status: VpsStatus }) => api.patch<Vps>(`/beheer/vps/${id}`, data),
    delete: (id: string) => api.delete(`/beheer/vps/${id}`),
    start: (id: string) => api.post<{ detail: string }>(`/beheer/vps/${id}/start`),
    stop: (id: string) => api.post<{ detail: string }>(`/beheer/vps/${id}/stop`),
  },
  network: {
    list: (params?: { status?: IPAddressStatus }) =>
      api.get<AdminNetworkResponse>("/beheer/network", { params }),
  },
  reconcile: {
    status: () => api.get<ReconcileStatusResponse>("/beheer/reconcile"),
    trigger: () => api.post<{ task_id: string }>("/beheer/reconcile"),
  },
  logs: {
    list: (params?: Record<string, unknown>) =>
      api.get<PaginatedResponse<AuditLog>>("/beheer/logs", { params }),
    exportUrl: (params?: Record<string, string>) =>
      `${API_URL}/api/v1/beheer/logs/export?${new URLSearchParams(params).toString()}`,
  },
};

export const billingApi = {
  overview: () => api.get<BillingOverview>("/billing/overview"),
  settings: {
    get: () => api.get<BillingSettings>("/billing/settings"),
    update: (data: Partial<BillingSettings>) => api.post<BillingSettings>("/billing/settings", data),
  },
  invoices: {
    list: (params?: { status?: string }) =>
      api.get<{ count: number; results: Invoice[] }>("/invoices", { params }),
    get: (id: string) => api.get<Invoice>(`/invoices/${id}`),
    pay: (id: string) =>
      api.post<{ detail: string; invoice_status: string; paid_at: string }>(`/invoices/${id}/pay`),
    downloadUrl: (id: string) => `${API_URL}/api/v1/invoices/${id}/download`,
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
