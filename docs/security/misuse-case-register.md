# Bunk-Fleet — Misuse-Case Register

A standing register of abuse scenarios across the platform (control plane, worker agent, frontend, edge), each marked **DEFENDED** (with the code that defends it) or **OPEN** (with the mitigation). Built 2026-06-29; covers 40 cases. Most are already defended — this register exists to keep them honest and to drive the remaining work.

## Status summary
- **40 misuse cases enumerated; ~27 DEFENDED, 13 OPEN.**
- OPEN items fixed this round: **O-23** (VPS name length cap), **O-29** (operators can only mint community-tier enroll tokens). Plus a correctness fix: ESXi `power()` rejects unknown ops instead of a nil-deref.
- The remaining OPEN items are the structural ones below — they need careful, isolated change on the live billing/scheduling paths and are the next implementation round.

## DEFENDED (verified in code — do not re-chase)
Auth: credential stuffing (constant-time verify + 30/min + 20/min browser throttle), TOTP brute (rate-limited), session theft/fixation (hashed tokens, renew-on-login, logout_all), self-promotion to admin (registration drops role; only :operator self-service; dashboard admin-only). Billing: negative balance / double-spend / concurrent-charge race (per-user advisory lock + in-tx balance check), top-up double-credit (FOR UPDATE + pending-only), Mollie webhook forgery/replay (fetch-to-verify + idempotent + amount from our DB), self-confirm top-up (admin-only confirm), refund abuse (positive-only, server-side). VPS: IDOR on all actions (owner-scoped get_vps_for_owner → 404), owner spoofing (owner stamped server-side, status hardcoded), huge specs (vcpu≤64/ram≤256G/disk≤8192G), orphaned reservations (in-tx release + reconciler reclaim). Worker: command spoofing (node-scoped poll/result/heartbeat), heartbeat lying on available_* (scheduler-owned, never agent-set), command replay (FOR UPDATE + agent dedup by id), enroll-token abuse (single-use, FOR UPDATE, hashed), malicious overlay/network params (agent validates before wg-quick; CP validates declared network). Console: cross-tenant attach (ticket bound to {vps_id,user_id} + re-checked owner), ticket replay (ETS take = single-use, 60s TTL). API: mass-assignment (server-stamped), injection SQL/atom/command (parameterized + to_existing_atom + no shell), SSRF (hypervisor URLs live on the agent, never fetched by the CP), verbose errors (atoms sanitized, UUIDs validated).

## OPEN — prioritized (the next implementation round)

| # | Sev | Misuse | Mitigation | Locus |
|---|-----|--------|-----------|-------|
| **O-9** | **HIGH** | Free VPS via REST `POST /api/v1/vpses` — `create_vps_for_owner` charges nothing (only the LiveView portal charges). | Charge the wallet atomically on every create path; refund on failure. **Blocked on unifying two pricing models** (portal = size-based `@size_prices_cents`; REST = package `price_monthly`). Pick package-based as canonical, charge in `create_vps_for_owner`, drop the portal's separate size charge. | provisioning.ex:73-92, portal_live.ex:41 |
| **O-24** | **HIGH** | A hostile `:community` node advertises huge `total_*`, wins the (region-only) scheduler, and attracts other tenants' VMs onto member hardware (operator has full disk/RAM access). | Tier-gate scheduling (don't co-mingle customer workloads onto community nodes, or restrict which SKUs land there); bound advertised `total_*`; verify capacity out-of-band (benchmark). | scheduler.ex:82-112, fleet.ex:220-229, node.ex:179-192 |
| **O-33** | **MED→HIGH** | Console SSH does no host-key verification → the hosting operator can MITM the browser console. | TOFU-pin: record each VPS's SSH host key at provision, verify in `is_host_key/5` (at least for non-datacenter tiers). | console/key_cb.ex:13, console/session.ex:44 |
| **O-17** | **MED** | Payout inflation: metering bills `:active`, which only changes on the operator's own ACK; withholding stop/delete keeps accruing payout. | Stop metering once a stop/delete command is in-flight past a deadline; reconcile against an independent power-state report. | billing.ex:133-188, provisioning.ex:443-473 |
| **O-10** | **MED** | Metered customer usage is never debited from the wallet / no suspend-at-zero-balance. | Periodically settle `Billing.customer_usage` into `Credits`; suspend/stop VPSes for owners at zero. | billing.ex:328-358 |
| **O-39** | **MED** | `CF-Connecting-IP` is client-supplied at the edge (no Cloudflare allowlist) → per-IP rate limits bypassable IF the origin is reachable directly. *Largely mitigated by topology* (origin only reachable via the tunnel; Cloudflare overwrites the header), but no defense-in-depth. | Firewall the origin to Cloudflare ranges, or strip a client-supplied CF-Connecting-IP at the edge. | edge.conf, plugs/rate_limit.ex |
| **O-7** | **MED** | No email verification + automatic €10 signup bonus → throwaway-account credit/compute farming (compounds O-9). | Gate the bonus + provisioning on a verified, rate-limited identity. | accounts.ex:88-97 |
| **O-3** | LOW | TOTP code replay within its ~30s step (no `:since`). | Persist `totp_last_used_step`, pass `since:`. | accounts.ex:75 |
| **O-20** | LOW | Quota check is unlocked TOCTOU → can slightly exceed `max_vpses_per_owner`. | Advisory-lock the count+insert in `create_vps_for_owner` (do together with O-9). | provisioning.ex:73-104 |
| **O-23** | LOW | ~~Unbounded VPS name.~~ **FIXED** — `validate_length(:name, max: 100)`. Still TODO: cap `cloud_init`/`ssh_keys` size. | — | fleet/vps.ex |
| **O-29** | LOW | ~~Operator self-mints `:datacenter` tier.~~ **FIXED** — operator tokens forced to `:community`. | — | operator_controller.ex |
| **O-38** | LOW | Admin/operator list endpoints lack pagination. | Add limit/offset. | fleet.ex:49-70 |
| **O-40** | LOW | Unauth Mollie webhook is unthrottled + makes one outbound fetch per hit. | Light rate-limit + short-circuit unknown ids before fetching. | mollie_controller.ex:57-78 |
| — | INFO | No password-reset/recovery flow exists (lockout risk, not a vuln). | New feature. | — |

**Two highest-leverage:** O-9 (breaks the credit economy outright) and O-24 (breaks tenant isolation in the federation model); O-33 + O-17 compound O-24.
