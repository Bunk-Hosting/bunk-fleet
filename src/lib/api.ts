import axios from "axios";
import type {
  User,
  Vps,
  VpsCredentials,
  VpsPackage,
  AdminStats,
  AdminNetworkResponse,
  AuditLog,
  IPAddressStatus,
  PaginatedResponse,
  OsChoice,
  VpsStatus,
  ReconcileStatusResponse,
  BillingSettings,
  BillingOverview,
  Invoice,
  CompanySettings,
  AdminBillingOverview,
} from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";

function getCsrfToken(): string {
  if (typeof document === "undefined") return "";
  const match = document.cookie.match(/csrftoken=([^;]+)/);
  return match ? match[1] : "";
}

// Haalt de CSRF-cookie op van de backend. Aanroepen vóór de eerste POST
// als de gebruiker nog geen cookie heeft (bijv. direct naar /login navigeren).
export async function ensureCsrfCookie(): Promise<void> {
  if (getCsrfToken()) return;
  await axios.get(`${API_URL}/api/v1/health/`, { withCredentials: true });
}

const api = axios.create({
  baseURL: `${API_URL}/api/v1`,
  withCredentials: true,
  headers: {
    "Content-Type": "application/json",
  },
});

api.interceptors.request.use((config) => {
  if (config.method && ["post", "put", "patch", "delete"].includes(config.method)) {
    config.headers["X-CSRFToken"] = getCsrfToken();
  }
  return config;
});

let isRefreshing = false;
let failedQueue: Array<{
  resolve: (value?: unknown) => void;
  reject: (reason?: unknown) => void;
}> = [];

function processQueue(error: unknown) {
  failedQueue.forEach((prom) => {
    if (error) {
      prom.reject(error);
    } else {
      prom.resolve();
    }
  });
  failedQueue = [];
}

api.interceptors.response.use(
  (response) => response,
  async (error) => {
    const originalRequest = error.config;

    if (
      error.response?.status === 401 &&
      !originalRequest._retry &&
      !originalRequest.url?.includes("/auth/token/refresh/") &&
      !originalRequest.url?.includes("/auth/login/")
    ) {
      if (isRefreshing) {
        return new Promise((resolve, reject) => {
          failedQueue.push({ resolve, reject });
        }).then(() => api(originalRequest));
      }

      originalRequest._retry = true;
      isRefreshing = true;

      try {
        await axios.post(
          `${API_URL}/api/v1/auth/token/refresh/`,
          {},
          { withCredentials: true, headers: { "X-CSRFToken": getCsrfToken() } }
        );
        processQueue(null);
        return api(originalRequest);
      } catch (refreshError) {
        processQueue(refreshError);
        if (typeof window !== "undefined") {
          window.location.href = "/login";
        }
        return Promise.reject(refreshError);
      } finally {
        isRefreshing = false;
      }
    }

    return Promise.reject(error);
  }
);

// ─── Auth ────────────────────────────────────────────────────────────
export const authApi = {
  register: (
    name: string,
    email: string,
    password: string,
    password_confirm: string,
    turnstile_token?: string,
  ) =>
    api.post<{ detail: string }>("/auth/register/", {
      name,
      email,
      password,
      password_confirm,
      ...(turnstile_token ? { turnstile_token } : {}),
    }),

  login: (email: string, password: string, turnstileToken?: string) => {
    const data: Record<string, string> = { email, password };
    if (turnstileToken) data.turnstile_token = turnstileToken;
    return api.post<{
      detail: string;
      otp_required?: boolean;
      totp_required?: boolean;
      verification_required?: boolean;
      turnstile_required?: boolean;
    }>("/auth/login/", data);
  },

  loginOtp: (email: string, code: string) =>
    api.post<{ user: User; message: string }>("/auth/login/otp/", { email, code }),

  loginTotp: (email: string, code: string) =>
    api.post<{ user: User; message: string }>("/auth/login/totp/", { email, code }),

  logout: () => api.post("/auth/logout/"),

  me: () => api.get<User>("/auth/me/"),

  verifyEmail: (token: string) =>
    api.post<{ detail: string }>("/auth/verify-email/", { token }),

  resendVerification: () =>
    api.post<{ detail: string }>("/auth/verify-email/resend/"),

  requestPasswordReset: (email: string) =>
    api.post<{ detail: string }>("/auth/password-reset/", { email }),

  confirmPasswordReset: (token: string, password: string, password_confirm: string) =>
    api.post<{ detail: string }>("/auth/password-reset/confirm/", { token, password, password_confirm }),

  totp: {
    setup: () =>
      api.get<{ secret: string; qr_data_url: string }>("/auth/totp/setup/"),
    confirm: (code: string) =>
      api.post<{ detail: string }>("/auth/totp/setup/", { code }),
    disable: (code: string) =>
      api.delete<{ detail: string }>("/auth/totp/disable/", { data: { code } }),
  },
};

// ─── Packages ────────────────────────────────────────────────────────
export const packagesApi = {
  list: () => api.get<{ count: number; results: VpsPackage[] }>("/packages/"),
};

// ─── VPS ─────────────────────────────────────────────────────────────
export const vpsApi = {
  list: () => api.get<{ count: number; results: Vps[] }>("/vps/"),

  get: (id: number) => api.get<Vps>(`/vps/${id}/`),

  create: (data: { label?: string; package_id: number; os: OsChoice }) =>
    api.post<Vps>("/vps/", data),

  credentials: (id: number) => api.get<VpsCredentials>(`/vps/${id}/credentials/`),

  delete: (id: number) => api.delete(`/vps/${id}/`),

  start: (id: number) => api.post<{ detail: string }>(`/vps/${id}/start/`),

  stop: (id: number) => api.post<{ detail: string }>(`/vps/${id}/stop/`),
};

// ─── Admin ───────────────────────────────────────────────────────────
export const adminApi = {
  stats: () => api.get<AdminStats>("/beheer/stats/"),

  users: {
    list: () => api.get<{ count: number; results: User[] }>("/beheer/users/"),

    get: (id: number) => api.get<{ user: User; vps: Vps[] }>(`/beheer/users/${id}/`),

    update: (id: number, data: { role?: "user" | "admin"; is_active?: boolean }) =>
      api.patch<User>(`/beheer/users/${id}/`, data),
  },

  vps: {
    list: (params?: { status?: VpsStatus; owner_id?: number; os?: OsChoice }) =>
      api.get<{ count: number; results: Vps[] }>("/beheer/vps/", { params }),

    get: (id: number) => api.get<Vps>(`/beheer/vps/${id}/`),

    create: (data: { label?: string; package_id: number; os: OsChoice; owner_id: number }) =>
      api.post<Vps>("/beheer/vps/", data),

    update: (id: number, data: { status: VpsStatus }) =>
      api.patch<Vps>(`/beheer/vps/${id}/`, data),

    delete: (id: number) => api.delete(`/beheer/vps/${id}/`),

    start: (id: number) => api.post<{ detail: string }>(`/beheer/vps/${id}/start/`),

    stop: (id: number) => api.post<{ detail: string }>(`/beheer/vps/${id}/stop/`),
  },

  network: {
    list: (params?: { status?: IPAddressStatus }) =>
      api.get<AdminNetworkResponse>("/beheer/network/", { params }),
  },

  reconcile: {
    status: () => api.get<ReconcileStatusResponse>("/beheer/reconcile/"),
    trigger: () => api.post<{ task_id: string }>("/beheer/reconcile/"),
  },

  logs: {
    list: (params?: {
      user_id?: number;
      action?: string;
      resource?: string;
      status_code?: number;
      date_from?: string;
      date_to?: string;
      page?: number;
      page_size?: number;
    }) => api.get<PaginatedResponse<AuditLog>>("/beheer/logs/", { params }),

    exportUrl: (params?: Record<string, string>) => {
      const searchParams = new URLSearchParams(params);
      return `${API_URL}/api/v1/beheer/logs/export/?${searchParams.toString()}`; // beheer ipv admin — Cloudflare WAF vermijding
    },
  },
};

// ─── Billing (gebruiker) ──────────────────────────────────────────────────────
export const billingApi = {
  overview: () => api.get<BillingOverview>("/billing/overview/"),

  settings: {
    get: () => api.get<BillingSettings>("/billing/settings/"),
    update: (data: Partial<BillingSettings>) =>
      api.post<BillingSettings>("/billing/settings/", data),
  },

  invoices: {
    list: (params?: { status?: string }) =>
      api.get<{ count: number; results: Invoice[] }>("/invoices/", { params }),
    get: (id: number) => api.get<Invoice>(`/invoices/${id}/`),
    pay: (id: number) =>
      api.post<{ detail: string; invoice_status: string; paid_at: string }>(
        `/invoices/${id}/pay/`
      ),
    downloadUrl: (id: number) =>
      `${API_URL}/api/v1/invoices/${id}/download/`,
  },
};

// ─── Admin Billing ────────────────────────────────────────────────────────────
export const adminBillingApi = {
  overview: () => api.get<AdminBillingOverview>("/beheer/billing/overview/"),

  company: {
    get: () => api.get<CompanySettings>("/beheer/billing/company/"),
    update: (data: Partial<CompanySettings>) =>
      api.post<CompanySettings>("/beheer/billing/company/", data),
  },

  invoices: {
    list: (params?: { status?: string; user_id?: number }) =>
      api.get<{ count: number; results: Invoice[] }>("/beheer/billing/invoices/", { params }),
    get: (id: number) => api.get<Invoice>(`/beheer/billing/invoices/${id}/`),
    update: (id: number, data: { status: string }) =>
      api.patch<Invoice>(`/beheer/billing/invoices/${id}/`, data),
  },
};

// ─── Error helper ─────────────────────────────────────────────────────────────
/**
 * Vertaalt een onbekende fout naar een veilige, gebruiksvriendelijke melding.
 * Nooit raw backend-data doorsturen naar de gebruiker.
 *
 * @param err      De gevangen fout (unknown)
 * @param fallback Melding bij een 400 of onverwachte status (context-specifiek)
 */
export function parseApiError(err: unknown, fallback = "Er is een fout opgetreden."): string {
  if (!axios.isAxiosError(err)) return fallback;
  if (!err.response) return "Geen verbinding. Controleer je internetverbinding.";
  switch (err.response.status) {
    case 400: return fallback;
    case 401: return "Je bent niet ingelogd.";
    case 403: return "Je hebt geen toegang.";
    case 404: return "Niet gevonden.";
    case 429: return "Te veel pogingen. Probeer het later opnieuw.";
    default:
      return err.response.status >= 500
        ? "Er is een serverfout opgetreden. Probeer het later opnieuw."
        : fallback;
  }
}

export default api;
