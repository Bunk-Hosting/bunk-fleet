# Bunk-Fleet — Misuse-Case Register

A standing register of abuse scenarios across the platform (control plane, worker agent, frontend, edge), each marked **DEFENDED** (with the code that defends it) or **OPEN** (with the mitigation). Built 2026-06-29; covers 40 cases. Most are already defended — this register exists to keep them honest and to drive the remaining work.

> **2026-09-09 — the threat model changed.** Bunk no longer runs a federated
> fleet: every node is our own hardware and no customer operates one. The whole
> class of "hostile external operator" misuse — a member advertising fake
> capacity, inspecting a co-tenant's disk/RAM, MITM'ing a console, or withholding
> a teardown ACK to inflate their payout — **no longer has an actor**. O-24 and
> O-29 are closed for that reason (not because they were fixed), and O-17 loses
> its fraud motive though the correctness fix stands. The `:datacenter`/`:community`
> node tier that O-24 introduced has been removed from the code.
>
> What remains, and is now the whole game: **tenant-vs-tenant isolation** and
> **customer-vs-Bunk billing integrity**. Those rows are unaffected.

## Status summary
- **40 misuse cases enumerated; ~27 DEFENDED, 13 OPEN.**
- OPEN items fixed this round: **O-23** (VPS name length cap), ~~O-29~~ (moot — see the 2026-09-09 note). Plus a correctness fix: ESXi `power()` rejects unknown ops instead of a nil-deref.
- Fixed in later rounds: **O-9** (`create_vps_for_owner` charges server-authoritative package price, 0de036c), **O-3** (TOTP replay window closed with `:since`, 4dbf6d7), **O-17** (metering stops once a stop/pause/delete is in-flight, 6c1c4a7), **O-20** (advisory-locked quota check, c01583b), **O-33** (console host-key TOFU pinning, 02e5023). **O-24** closed by the 2026-09-09 pivot — there is no untrusted node operator left to defend against; the tier mechanism it introduced has been deleted.
- The remaining OPEN items are the structural ones below — they need careful, isolated change on the live billing/scheduling paths and are the next implementation round.

## DEFENDED (verified in code — do not re-chase)
Auth: credential stuffing (constant-time verify + 30/min + 20/min browser throttle), TOTP brute (rate-limited), session theft/fixation (hashed tokens, renew-on-login, logout_all), self-promotion to admin (registration drops role; role elevation is admin-only; dashboard admin-only). Billing: negative balance / double-spend / concurrent-charge race (per-user advisory lock + in-tx balance check), top-up double-credit (FOR UPDATE + pending-only), Mollie webhook forgery/replay (fetch-to-verify + idempotent + amount from our DB), self-confirm top-up (admin-only confirm), refund abuse (positive-only, server-side). VPS: IDOR on all actions (owner-scoped get_vps_for_owner → 404), owner spoofing (owner stamped server-side, status hardcoded), huge specs (vcpu≤64/ram≤256G/disk≤8192G), orphaned reservations (in-tx release + reconciler reclaim). Worker: command spoofing (node-scoped poll/result/heartbeat), heartbeat lying on available_* (scheduler-owned, never agent-set), command replay (FOR UPDATE + agent dedup by id), enroll-token abuse (single-use, FOR UPDATE, hashed), malicious overlay/network params (agent validates before wg-quick; CP validates declared network). Console: cross-tenant attach (ticket bound to {vps_id,user_id} + re-checked owner), ticket replay (ETS take = single-use, 60s TTL). API: mass-assignment (server-stamped), injection SQL/atom/command (parameterized + to_existing_atom + no shell), SSRF (hypervisor URLs live on the agent, never fetched by the CP), verbose errors (atoms sanitized, UUIDs validated).

## OPEN — prioritized (the next implementation round)

| # | Sev | Misuse | Mitigation | Locus |
|---|-----|--------|-----------|-------|
| **O-9** | **HIGH** | Free VPS via REST `POST /api/v1/vpses` — `create_vps_for_owner` charges nothing (only the LiveView portal charges). | Charge the wallet atomically on every create path; refund on failure. **Blocked on unifying two pricing models** (portal = size-based `@size_prices_cents`; REST = package `price_monthly`). Pick package-based as canonical, charge in `create_vps_for_owner`, drop the portal's separate size charge. | provisioning.ex:73-92, portal_live.ex:41 |
| ~~**O-24**~~ | ~~HIGH~~ | ~~A hostile `:community` node advertises huge `total_*`, wins the scheduler, and attracts other tenants' VMs onto member hardware.~~ **CLOSED 2026-09-09 — no actor.** Every node is ours; there is no external operator with disk/RAM access to a co-tenant's VM. The tier mechanism built for this has been removed. Bounding advertised `total_*` survives as a *robustness* item (a buggy agent can still overstate capacity and cause overselling), not a security one. | — | scheduler.ex, fleet/node.ex |
| ~~**O-33**~~ | ~~MED→HIGH~~ | ~~Console SSH does no host-key verification → the hosting operator can MITM the browser console.~~ **FIXED (02e5023)** — TOFU-pin in `Console.HostKeys.verify/2`: `vpses.ssh_host_key` records the SHA256 fingerprint on first console connect; later connects must match or are rejected fail-closed (`silently_accept_hosts: fn _,_ -> false end`). | — | console/host_keys.ex, console/key_cb.ex |
| **O-17** | LOW (was MED) | ~~Payout inflation by withholding a teardown ACK.~~ No payout and no external actor, so the fraud motive is gone. The underlying *accuracy* concern stands: a VPS still counted `:active` after a stop overstates what a node served. Already mitigated — metering stops once a stop/pause/delete is in flight (6c1c4a7). | Reconcile against an independent power-state report. | billing.ex, provisioning.ex |
| ~~**O-10**~~ | — | ~~Metered customer usage is never debited / no suspend-at-zero-balance.~~ **RESOLVED — and the old mitigation was wrong.** Customers pay a monthly **subscription**, not metered usage: the runner charges the wallet on `next_billing_date`, and on insufficient credit stops the VPS, marks `:past_due` with retry tomorrow, and resumes on a later successful charge. So suspend-at-zero already exists. Settling `customer_usage` into `Credits` as originally proposed would have **double-charged** every customer on top of their subscription. `customer_usage/2` is read-only by design — it backs a GET endpoint so a customer can see their consumption. | — | subscriptions.ex:95-151 |
| **O-39** | **MED** | `CF-Connecting-IP` is client-supplied at the edge (no Cloudflare allowlist) → per-IP rate limits bypassable IF the origin is reachable directly. *Largely mitigated by topology* (origin only reachable via the tunnel; Cloudflare overwrites the header), but no defense-in-depth. | Firewall the origin to Cloudflare ranges, or strip a client-supplied CF-Connecting-IP at the edge. | edge.conf, plugs/rate_limit.ex |
| **O-7** | **MED** | No email verification + automatic €10 signup bonus → throwaway-account credit/compute farming (compounds O-9). | Gate the bonus + provisioning on a verified, rate-limited identity. | accounts.ex:88-97 |
| **O-3** | LOW | TOTP code replay within its ~30s step (no `:since`). | Persist `totp_last_used_step`, pass `since:`. | accounts.ex:75 |
| **O-20** | LOW | Quota check is unlocked TOCTOU → can slightly exceed `max_vpses_per_owner`. | Advisory-lock the count+insert in `create_vps_for_owner` (do together with O-9). | provisioning.ex:73-104 |
| **O-23** | LOW | ~~Unbounded VPS name.~~ **FIXED** — `validate_length(:name, max: 100)`. Still TODO: cap `cloud_init`/`ssh_keys` size. | — | fleet/vps.ex |
| ~~**O-29**~~ | — | ~~Operator self-mints `:datacenter` tier.~~ **MOOT 2026-09-09** — operator self-service and node tiers both removed. | — | (deleted) |
| **O-38** | LOW | Admin/operator list endpoints lack pagination. | Add limit/offset. | fleet.ex:49-70 |
| **O-40** | LOW | Unauth Mollie webhook is unthrottled + makes one outbound fetch per hit. | Light rate-limit + short-circuit unknown ids before fetching. | mollie_controller.ex:57-78 |
| — | INFO | No password-reset/recovery flow exists (lockout risk, not a vuln). | New feature. | — |

**Highest-leverage now that O-24 and O-10 are closed:** **O-7** — signup grants an automatic €10 bonus with no email verification, so throwaway accounts farm credit. That is the one remaining item that costs real money. Then O-39 (CF-Connecting-IP not allowlisted at the edge) as defence-in-depth. O-9 has since been fixed: `create_vps_for_owner` charges the server-authoritative package price.
