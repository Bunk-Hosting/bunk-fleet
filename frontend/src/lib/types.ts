export interface User {
  id: string;
  email: string;
  name: string;
  role: "user" | "admin";
  date_joined: string;
  is_active: boolean;
  vps_count?: number;
  totp_enabled: boolean;
  /** null until the user clicks the link in their confirmation email. */
  confirmed_at: string | null;
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
  id: string;
  label: string;
  package: VpsPackage;
  os: OsChoice;
  status: VpsStatus;
  ip_address: string | null;
  hostname: string | null;
  /**
   * Where this VPS is reachable from the internet. Null when the node it runs
   * on has no public address yet — in which case the browser console is the
   * only way in, and the UI has to say that rather than print the private
   * address as if it were an endpoint.
   */
  public_host: string | null;
  ssh_port: number | null;
  ssh_username: string;
  vcenter_vm_id: string | null;
  created_at: string;
  updated_at: string;
  owner: string;
  owner_email: string | null;
}

export interface VpsCredentials {
  ip_address: string | null;
  ssh_port: number | null;
  ssh_username: string;
  sudo_password: string | null;
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

export type IPAddressStatus = "FREE" | "ASSIGNED" | "RESERVED";

export interface IPAddressEntry {
  id: number;
  address: string;
  status: IPAddressStatus;
  assigned_at: string | null;
  vps_id: number | null;
  infra_name: string | null;
  owner_email: string | null;
  package_name: string | null;
}

export interface NetworkSummary {
  total: number;
  free: number;
  assigned: number;
  reserved: number;
}

export interface AdminNetworkResponse {
  summary: NetworkSummary;
  results: IPAddressEntry[];
}

export interface PaginatedResponse<T> {
  count: number;
  next: string | null;
  previous: string | null;
  results: T[];
}

export interface ReconcileResult {
  started_at: string;
  finished_at: string | null;
  vms_checked: number;
  vms_deleted: number;
  ips_released: number;
  orphaned_ips_released: number;
  error: string | null;
}

export interface ReconcileStatusResponse {
  interval_minutes: number;
  last_result: ReconcileResult | null;
}

// ─── Billing ──────────────────────────────────────────────────────────────────

export type InvoiceStatus = "draft" | "open" | "paid" | "void";
export type BillingCycle = "monthly" | "yearly";
export type PaymentStatus = "pending" | "succeeded" | "failed";

export interface BillingSettings {
  billing_cycle: BillingCycle;
  billing_email: string;
}

export interface BillingOverview {
  open_amount: string;
  open_invoice_count: number;
  monthly_cost: string;
  active_subscriptions: number;
  next_invoice_date: string | null;
}

export interface InvoiceLineItem {
  id: number;
  description: string;
  quantity: string;
  unit_price: string;
  line_total: string;
}

export interface Payment {
  id: number;
  amount: string;
  status: PaymentStatus;
  provider: string;
  attempted_at: string;
  succeeded_at: string | null;
}

export interface Invoice {
  id: number;
  invoice_number: string;
  status: InvoiceStatus;
  period_start: string;
  period_end: string;
  due_date: string;
  subtotal: string;
  discount_amount?: string;
  vat_rate?: string;
  vat_amount: string;
  total: string;
  company_name?: string;
  company_address?: string;
  company_vat_number?: string;
  company_kvk_number?: string;
  finalized_at?: string | null;
  paid_at: string | null;
  created_at: string;
  lines?: InvoiceLineItem[];
  payments?: Payment[];
}

export interface CompanySettings {
  company_name: string;
  address_line1: string;
  address_line2: string;
  postal_code: string;
  city: string;
  country: string;
  kvk_number: string;
  vat_number: string;
  vat_rate: string;
  vat_rate_percent: string;
  yearly_discount_rate: string;
  yearly_discount_percent: string;
  support_email: string;
  invoice_prefix: string;
  updated_at: string;
}

export interface AdminBillingOverview {
  open_invoices_count: number;
  open_invoices_total: string | number;
  paid_invoices_count: number;
  paid_invoices_total: string | number;
  active_subscriptions: number;
}
