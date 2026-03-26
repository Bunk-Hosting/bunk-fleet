export interface User {
  id: number;
  email: string;
  name: string;
  role: "user" | "admin";
  date_joined: string;
  is_active: boolean;
  vps_count?: number;
}

export type VpsStatus =
  | "PENDING"
  | "PROVISIONING"
  | "ACTIVE"
  | "STOPPED"
  | "DELETING"
  | "DELETED"
  | "ERROR";

export type OsChoice =
  | "ubuntu-22.04"
  | "ubuntu-20.04"
  | "debian-12"
  | "debian-11"
  | "centos-9"
  | "alpine-3.19";

export interface VpsPackage {
  id: number;
  name: string;
  cpu_cores: number;
  ram_gb: number;
  disk_gb: number;
  bandwidth_tb: number;
  price_monthly: string;
  description: string;
}

export interface Vps {
  id: number;
  label: string;
  package: VpsPackage;
  os: OsChoice;
  status: VpsStatus;
  ip_address: string | null;
  hostname: string | null;
  ssh_port: number;
  ssh_username: string;
  vcenter_vm_id: string | null;
  created_at: string;
  updated_at: string;
  owner: number;
  owner_email: string | null;
}

export interface VpsCredentials {
  ip_address: string | null;
  ssh_port: number;
  ssh_username: string;
  ssh_password: string | null;
}

export interface AuditLog {
  id: number;
  user: number | null;
  user_email: string | null;
  action: string;
  resource: string;
  ip_address: string | null;
  response_status: number | null;
  timestamp: string;
  extra_data: Record<string, unknown>;
}

export interface AdminStats {
  total_users: number;
  total_vps: number;
  active_vps: number;
  stopped_vps: number;
  error_vps: number;
}

export interface PaginatedResponse<T> {
  count: number;
  next: string | null;
  previous: string | null;
  results: T[];
}

export interface JwtPayload {
  user_id: number;
  email: string;
  name: string;
  role: "user" | "admin";
  exp: number;
}
