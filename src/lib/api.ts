import axios from "axios";
import type {
  User,
  Vps,
  VpsPackage,
  AdminStats,
  AdminNetworkResponse,
  AuditLog,
  IPAddressStatus,
  PaginatedResponse,
  OsChoice,
  VpsStatus,
  ReconcileStatusResponse,
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
          { withCredentials: true }
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
  login: (email: string, password: string) =>
    api.post<{ user: User; message: string }>("/auth/login/", { email, password }),

  register: (data: { name: string; email: string; password: string; password_confirm: string }) =>
    api.post<{ user: User; message: string }>("/auth/register/", data),

  logout: () => api.post("/auth/logout/"),

  me: () => api.get<User>("/auth/me/"),
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

  delete: (id: number) => api.delete(`/vps/${id}/`),

  start: (id: number) => api.post<{ detail: string }>(`/vps/${id}/start/`),

  stop: (id: number) => api.post<{ detail: string }>(`/vps/${id}/stop/`),
};

// ─── Admin ───────────────────────────────────────────────────────────
export const adminApi = {
  stats: () => api.get<AdminStats>("/admin/stats/"),

  users: {
    list: () => api.get<{ count: number; results: User[] }>("/admin/users/"),

    get: (id: number) => api.get<{ user: User; vps: Vps[] }>(`/admin/users/${id}/`),

    update: (id: number, data: { role?: "user" | "admin"; is_active?: boolean }) =>
      api.patch<User>(`/admin/users/${id}/`, data),
  },

  vps: {
    list: (params?: { status?: VpsStatus; owner_id?: number; os?: OsChoice }) =>
      api.get<{ count: number; results: Vps[] }>("/admin/vps/", { params }),

    get: (id: number) => api.get<Vps>(`/admin/vps/${id}/`),

    create: (data: { label?: string; package_id: number; os: OsChoice; owner_id: number }) =>
      api.post<Vps>("/admin/vps/", data),

    update: (id: number, data: { status: VpsStatus }) =>
      api.patch<Vps>(`/admin/vps/${id}/`, data),

    delete: (id: number) => api.delete(`/admin/vps/${id}/`),

    start: (id: number) => api.post<{ detail: string }>(`/admin/vps/${id}/start/`),

    stop: (id: number) => api.post<{ detail: string }>(`/admin/vps/${id}/stop/`),
  },

  network: {
    list: (params?: { status?: IPAddressStatus }) =>
      api.get<AdminNetworkResponse>("/admin/network/", { params }),
  },

  reconcile: {
    status: () => api.get<ReconcileStatusResponse>("/admin/reconcile/"),
    trigger: () => api.post<{ task_id: string }>("/admin/reconcile/"),
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
    }) => api.get<PaginatedResponse<AuditLog>>("/admin/logs/", { params }),

    exportUrl: (params?: Record<string, string>) => {
      const searchParams = new URLSearchParams(params);
      return `${API_URL}/api/v1/admin/logs/export/?${searchParams.toString()}`;
    },
  },
};

export default api;
