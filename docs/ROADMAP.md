# Bunk-Hosting — Product & Technical Roadmap

*Written as the engineering lead. Goal: a control plane with a UI where users register, pay with Mollie, and get a secure, automatically-provisioned VPS — plus the distributed "bring-your-own-hardware → earn credits" model as the differentiator. Grounded in the actual codebase at `4542465`.*

---

## 0. TL;DR — the honest state and the critical path

**What already works:** control plane + customer dashboard (Next.js), registration/login + 2FA, VPS lifecycle (create/start/stop/delete) with **real automatic Proxmox provisioning**, owner-scoped & race-safe authorization (just security-audited), a **credit wallet** (balance/charge/refund/top-up), per-VPS **subscriptions**, the **worker/operator API** (enroll → heartbeat → command → result) with a self-service "become a host" tab and an install wizard.

**What's missing for your vision, in priority order:**

| Layer | Missing | Why it blocks the vision |
|---|---|---|
| **Pay-to-rent** | Mollie integration; recurring billing runner; charge-on-API-create | Today a user can't actually *pay*; API VPS-create even bypasses the wallet (security M3). This is the #1 gap. |
| **Backups** | Snapshots + scheduled off-host backups | Without them the product isn't trustworthy, *especially* on home hardware. |
| **Worker economy** | Real earn-credits-for-capacity, benchmark/verification, reputation+uptime score, easy installer, "tested → credited" | This is your differentiator and barely exists beyond enrollment. |
| **Reliability** | Failover / auto-restart-elsewhere when a home host drops | Without it the distributed model is untrustworthy. Technically the hardest piece. |
| **Worker repo split** | agent/ → its own repo | Explicit ask; also right for trust (open the client, ship binaries). |
| **Security prereqs** | C1/H3/H4 worker-trust fixes | Must land *before* real external hosts connect (see §6). |
| **Platform polish** | noVNC console, snapshots UI, SSH-key mgmt, firewall, monitoring graphs, bandwidth metering/quota | Standard VPS UX; comes after the core loop is solid. |

**Critical path to "a stranger can pay and get a secure VPS":** Mollie top-up → wallet → atomic charge-on-create (fix M3/M4) → provision (works) → backups → done. That's **Phase 1** and it does *not* depend on the worker economy. Build the rentable product first; layer the federation on top.

---

## 1. Phased plan

### Phase 1 — Rentable, paid, backed-up VPS (the business core) — *no worker economy yet*
1. **Mollie payments → wallet top-up.** Replace the manual top-up with Mollie. Flow: user picks an amount (or a package) → create Mollie payment → redirect → **webhook** marks the top-up paid → `Credits.add_entry`. Implement **signature-checked, idempotent** webhook handling (the security review flagged this category as N/A *because it doesn't exist yet* — build it correctly from day one). iDEAL + card via Mollie.
2. **Atomic charge-on-provision (fixes security M3 + M4).** Move `Credits.charge` *inside* the `create_vps_for_owner` Ecto.Multi so both REST and portal paths charge consistently and roll back together; refund on any failure (including a raise).
3. **Recurring billing runner.** A daily job that charges each active `Subscription` on its `next_billing_date` from the wallet; on insufficient balance → grace period → suspend (stop) → after N days → delete. Email/dashboard warnings.
4. **Backups (see §2 for the design).** Daily scheduled snapshot → encrypted → shipped to **central** object storage; manual snapshot button; restore flow. This is non-negotiable for trust.
5. **Packages as data.** You already have packages in the DB (Starter/Basic/…). Keep **one active package** but make the catalog admin-managed (`is_available` flag) so adding packages is a data change, not a deploy. (Mostly already true — just expose an admin CRUD.)
6. **Harden:** rate-limit auth (security H2), the quick wins from the assessment.

**Exit criteria:** a new user registers → pays with Mollie → rents the one package → VPS auto-provisions on Proxmox → is backed up daily → is billed monthly → can be deleted. Secure and atomic.

### Phase 2 — The worker economy (your differentiator)
7. **Worker repo split** → `bunk-worker` (separate repo, see §5).
8. **One-command guided installer** (§4): `curl …/install.sh | bash` that auto-detects Proxmox, **creates its own API token** (or walks the user through it), enrolls, and self-tests.
9. **Benchmark + resource verification** at enroll + periodically (CPU/disk/net/RAM), cross-checked against claims → clamps the security M1 "capacity lying" hole.
10. **Earn-credits-for-capacity.** A metering job credits a host's wallet for capacity *provided and available* (and/or actually consumed by tenants), at a configured ratio (§3). "Worker connected + tested → X credits" onboarding bonus.
11. **Reputation + uptime score** per node (§3) → influences payout rate, scheduling weight, and which **reliability tier** a node qualifies for. Visible to admin and (a simplified version) to the host.
12. **Step-by-step onboarding page** in the dashboard (enhance the current "Mijn hardware" tab): explain the model, the earnings, the requirements (24/7, bandwidth), then the installer.

### Phase 3 — Reliability / failover (hardest, most important for trust)
13. **Tiered reliability** (§3.4): *Datacenter* tier (Bunk-owned/SLA) vs *Community* tier (home hosts, cheaper, best-effort). Tenants pick; pricing differs.
14. **Auto-failover for community VPSes:** on host-offline (missed heartbeats), restart the VPS on another node **from its last backup/replica** (RPO = last snapshot). Clear disclosure of the RPO. This is "restart-elsewhere," not live-migration — pragmatic and achievable.
15. **(Stretch) near-live replication** for a premium tier (periodic disk-diff shipping) to shrink RPO. Live migration across home hosts with no shared storage is a multi-quarter effort — explicitly *not* MVP.
16. **Region/country selection** for tenants (latency + AVG residency, ties to the GDPR review) — constrain the scheduler to the chosen region.

### Phase 4 — Standard VPS platform polish
17. VPS lifecycle completion: **reboot, rebuild (reinstall OS), resize**.
18. **noVNC web console** (you have an SSH console bridge; add VNC so people get in when SSH/network is broken) — *and* fix the console-auth ticket (security H5).
19. **Snapshots UI**, scheduled-backup management.
20. **SSH-key management**, **firewall / security groups**, **floating IPs**, **private networks** between a customer's own VPSes.
21. **Monitoring graphs** (CPU/RAM/disk/bandwidth) + **alerting**.
22. **Bandwidth metering + quota** — doubly important for home hosts (limited upload); meter egress, quota per package, and factor a host's bandwidth into its tier/payout.

---

## 2. Backups — design decision (necessary: **yes**)

A VPS product without backups is not sellable, and on **home hardware it's existential** (a host's disk dies → tenant data gone). Decision:

- **Where:** **NOT on the host.** Backups must leave the home machine or they provide zero durability. Ship to **central, Bunk-controlled object storage** (S3-compatible: MinIO you run, or Backblaze B2/Wasabi for cost). The host encrypts before upload; Bunk stores ciphertext (defense for the GDPR/host-trust problem too).
- **How:** Proxmox `vzdump` snapshot → `age`/`gpg` encrypt with a per-VPS key the host doesn't hold → upload. The agent does this on command from the control plane (new `backup` command kind).
- **Schedule:** **daily automatic** + **on-demand manual**. Retention: **7 daily + 4 weekly** (GFS-lite). Configurable per package later.
- **Restore:** pull → decrypt → restore to any node (this *is* the Phase-3 failover primitive — build backups first, get failover almost for free).
- **MVP cut:** start with daily encrypted off-host backup + manual snapshot + restore-to-same-node. Cross-node restore = the bridge to failover.

This single feature underpins both "trustworthy product" and "failover," so it's high in Phase 1.

---

## 3. The credit economy — the design decisions you must make now

This is the part that will bite later if under-specified. My recommended model (numbers are levers you set):

**3.1 Unit.** Peg **1 credit = €0.01** (transparent, maps to euros, plays nicely with the existing `*_cents` wallet). Top-ups via Mollie buy credits 1:1.

**3.2 Earning (host side).** A host earns credits for capacity **made available and healthy** (heartbeating), scaled by **actual tenant usage** so you don't pay for idle promises forever. Recommended: pay **~60–70% of the retail price of the capacity a host hosts**, modulated by the host's **reputation score** (a flaky host earns less per unit). Bunk keeps the spread (covers the renter discount + margin + central backup storage cost).

**3.3 Spending.** Credits buy VPS-time at **retail**. So bringing hardware effectively gives you a discount, not free infinite hosting — sustainable. Your "double/half of what you bring in" idea works as a **launch incentive** (e.g. 2× earn-rate for the first N months) rather than a permanent rule, or it bankrupts the economy. I'd recommend framing it as a bonus, not the steady state.

**3.4 The three hard rules (decide explicitly):**
- **Do credits expire?** Recommendation: **yes — 12 months of inactivity**, then they lapse (with warning emails). Prevents an unbounded liability on your books and is defensible. *(Business decision — confirm.)*
- **Exact ratio?** Earn 60–70% of retail (reputation-scaled), spend at 100%. *(Business decision — confirm the %.)*
- **What if a host pulls their machine while a tenant runs on it?** This is the failover question (§Phase 3). Policy: tenants on **Community tier** accept a documented RPO; on host-offline the VPS auto-restarts elsewhere from its last backup. A host that yanks hardware with running tenants takes a **reputation hit** and may forfeit pending (unsettled) credits for that period. Critical workloads must use **Datacenter tier**. *(This must be disclosed to tenants — ties to GDPR.)*

**3.5 Reputation + uptime score (0–100).** Inputs: heartbeat uptime %, MTBF, node age, successful-provision rate, benchmark consistency (claimed vs measured), and bandwidth. Effects: **scheduling weight** (good nodes get more placements), **payout rate**, and **tier eligibility** (only ≥X score + 24/7 + verified resources qualify for Community-with-failover; the rest are "spot"/cheapest). **Admin sees the full score + history**; the host sees a simplified badge. This directly answers "admin wil zien hoe betrouwbaar een worker is."

**3.6 Resource verification.** Benchmark at enroll (CPU `sysbench`, disk `fio`, RAM size, net `iperf`/speedtest) + **periodic re-checks**; persist measured vs claimed; the scheduler trusts **measured**, not claimed (closes security M1). A node that benchmarks far below claim is clamped and loses reputation.

---

## 4. The installer — UX decision

Goal: "redelijk eenvoudig" for a non-expert with a Proxmox box. Design:

- **One line** from the dashboard: `curl -fsSL https://<cp>/install.sh | bash` (a wizard already exists — extend it).
- **Interactive but maximally automated:** it should
  1. detect it's running on Proxmox (`pveversion`), refuse politely otherwise with a link to docs;
  2. **auto-create its own least-privilege API token** via `pveum` (so the user doesn't hand-craft tokens) — or, if they prefer, paste one;
  3. ask only what it can't infer: which **enroll-token** (pre-filled if launched from the dashboard with `--token`), **region/country**, and a friendly **node name**;
  4. install the agent as a **systemd service** (durable across reboots — we learned this lesson the hard way with the tunnel), enroll, and **run the benchmark + a test provision**;
  5. report back; on success the dashboard flips the node to **online + verified** and **grants the onboarding credit bonus**.
- **The dashboard page** gets a real **step-by-step** explainer: what the model is, what you earn, requirements (24/7, upload bandwidth, a spare Proxmox host), then the copy-paste line and a live status that updates as the node comes up.

---

## 5. Worker software in a separate repo (your explicit ask)

**Recommended:** new repo **`Bunk-Hosting/bunk-worker`** (private to start; consider public later — open-sourcing the client builds trust for a "run it on your own hardware" product).
- Move `agent/` there; keep a small **shared protocol contract** (the JSON shapes for enroll/heartbeat/command/result) documented in both repos (or a tiny `bunk-protocol` repo) so they don't drift.
- CI builds **signed release binaries** + the container image `ghcr.io/bunk-hosting/bunk-worker` (the install command already references this image).
- The control plane keeps serving `/install.sh`; the script pulls the released binary/image.
- **Do this in Phase 2**, and **only after** the security prereqs (§6) — splitting the repo is the natural moment to also fix the agent's trust issues.

## 6. Security prerequisites (from the 2026-06-29 assessment — `docs/security/`)

Before a **real external** host connects, these must be fixed (today the node API isn't even publicly reachable, which is the only thing keeping them latent):
- **C1** WireGuard overlay RCE, **H3** enforce TLS + mTLS on the agent channel, **H4** command replay protection, **H5** console-auth ticket, **M1** capacity-lying (covered by §3.6 verification). The federation model is only as trustworthy as these fixes.

---

## 7. What I need from you to start building (business decisions, not engineering)

1. **Mollie:** do you have a Mollie account + API keys (test + live)? I can build the integration but need the keys (and your preferred methods — iDEAL, card, both).
2. **Credit ratio + expiry:** confirm earn ≈ 60–70% of retail (reputation-scaled), spend at 100%, credits expire after 12 mo inactivity — or give me your numbers. And is "double what you bring in" a launch bonus or a permanent rule?
3. **Reliability tiers:** OK to launch with two tiers — *Datacenter* (your hardware, SLA) and *Community* (home hosts, cheaper, best-effort + auto-restart-from-backup)? This shapes pricing, scheduling, and the failover build.
4. **Backups storage:** self-hosted MinIO (cheaper/control, more ops) vs a managed S3 (Backblaze B2/Wasabi, easy, small cost)? I recommend B2 to start.
5. **Worker repo:** name `bunk-worker`, private to start — OK? (I'll need it created under the org, or I can scaffold and you create it.)

---

## 8. What I'll start immediately once you confirm direction

Lowest-ambiguity, highest-leverage first, in order:
1. **Mollie top-up + atomic charge-on-create + recurring billing runner** (the rentable core) — needs your Mollie keys.
2. **Backups** (daily encrypted off-host + manual + restore) — needs the storage choice (#4).
3. **Worker repo split + guided installer + benchmark/verification + reputation score** — the federation layer.
4. Then platform polish (console/noVNC, snapshots UI, monitoring, bandwidth quota).

I can begin #2 and the security prereqs (§6) **without** any blocker; #1 needs Mollie keys; the economy details (#3 above) gate the worker-payout code.
