# Bunk-Hosting — AVG/GDPR Engineering & Process Review

> **Achterhaald sinds 9 september 2026. Lees dit niet als de huidige situatie.**
>
> Dit stuk gaat uit van het federatiemodel: leden installeren een worker op
> hardware bij hen thuis en hosten daarop de VM's van vreemden. Dat model is
> losgelaten. Bunk draait nu op eigen capaciteit, met één node bij een
> betrokkene, allemaal in Nederland. Daarmee vervalt de aanname die de
> zwaarste conclusies hieronder droeg — "de gegevens van een klant staan op de
> machine van een vreemde".
>
> Wat er nog wél toe doet is de analyse per verplichting: grondslagen,
> bewaartermijnen, de rol van verwerker bij VM-inhoud, en het onderscheid
> tussen beveiligingslogs en de rest. Die redeneringen zijn overgenomen in
> [verwerkingsregister.md](verwerkingsregister.md), en dát is het document dat
> de huidige stand beschrijft.

**Scope:** engineering + process recommendations (not legal advice). NL-based controller, mostly-EU data subjects. Based on the actual bunk-fleet codebase (control plane Elixir/Postgres, Go worker agent, Next.js frontend) at commit `335bb9f`.

**The non-standard bit, up front:** Bunk runs a *distributed* model — members install a "worker" on hardware **in their own home** and host **other people's VMs** on it. So a tenant's data physically lives on a stranger's machine, and that tenant's traffic exits a stranger's home IP. That single fact drives most of the harder obligations below (sub-processors, residency, transparency, security-of-processing).

---

## 0. Executive summary (gap analysis)

| # | Gap (today) | Risk | Priority |
|---|---|---|---|
| G1 | **No retention limits / auto-deletion.** `usage_records`, VPS rows (incl. `ip_address`), audit/request logs, agent logs are kept indefinitely. | Art. 5(1)(e) storage limitation; "lots of logs" becomes a liability | **P0** |
| G2 | **Home hosts are undeclared sub-processors.** No sub-processor agreement, no list, no tenant disclosure that their VM runs on third-party hardware. | Art. 28 (processor chain), Art. 13 transparency, Art. 32 security | **P0** |
| G3 | **No verwerkingsregister (Art. 30 record).** | Art. 30 | **P0** |
| G4 | **No data-subject-rights flows** (access/export/rectify/erase). Erasure not designed against backups + logs you want to keep. | Art. 15–17, 20 | **P0** |
| G5 | **IP addresses stored in the clear, no minimization/pseudonymization,** mixed into the same store as everything else; no split between security logs (legitimate interest) and analytics (consent). | Art. 5(1)(c), 6, 25 | **P1** |
| G6 | **No DPAs in place** with processors (Mollie if/when added, hosting infra, Cloudflare which currently terminates TLS and sees all traffic + client IPs). | Art. 28 | **P1** |
| G7 | **No cookie/consent layer or privacy policy** surfaced in the dashboard; Turnstile + any analytics unaccounted for. | ePrivacy/Telecomwet + Art. 13 | **P1** |
| G8 | **No DPIA**, despite large-scale monitoring + novel distributed processing (likely triggers Art. 35). | Art. 35 | **P1** |
| G9 | **Tenant data at rest on hostile hosts is not encrypted by Bunk** (disk encryption keyed to the host, not the tenant). | Art. 32 | **P1** |

Detailed remediation with the actual code/config change is in §3–§9. The fillable register template is §1. The lawyer questions are at the end.

---

## 1. Data mapping / verwerkingsregister (Art. 30)

### 1a. What personal data the platform actually touches (from the code)

| Category | Concrete fields | Where stored | Who can access | Lawful basis (see §2) | Proposed retention |
|---|---|---|---|---|---|
| **Account** | `users.email`, `users.name`, `hashed_password` (bcrypt, redacted), `totp_secret` (binary, redacted), `role`, `confirmed_at` | control-plane Postgres (`bf-prod-pg`) | the user; Bunk admins | Contract (Art. 6(1)(b)) | life of account + **90 d** after deletion (fraud/dispute), then purge |
| **Session/auth tokens** | `user_tokens` (hashed bearer tokens), TOTP state | Postgres | system | Contract / security (legit. interest) | token TTL; revoke on logout; **30 d** max |
| **VPS metadata** | `vpses.name`, `owner_email`, `ip_address` (assigned VM IP), `provider_vm_id`, specs | Postgres | owner; admins; **the host operator's node** | Contract | life of VPS + **30 d**, then purge (see erasure §4) |
| **Tenant content inside the VM** | OS, files, databases — *Bunk does not read it, but it lives on the host's disk* | **the home host's physical disk** (third party) | the tenant; **potentially the host operator (root on the box)** | Contract; **this is the headline risk** | controlled by tenant; destroyed on VM delete + disk wipe |
| **Metering / usage** | `usage_records.owner_email`, seconds, vcpu/ram/disk, `metered_at` | Postgres | owner; billing; operator (aggregate for payout) | Contract (billing) + legal retention | **invoicing rows: 7 y** (NL fiscale bewaarplicht, AWR art. 52); raw per-VM telemetry: aggregate then **drop raw at 90 d** |
| **Operator/host data** | `nodes.owner_email`, node capacity, home **IP/endpoint**, payout figures | Postgres + agent `state.json` | operator; admins | Contract (operator agreement) | life of node + 7 y for payout records |
| **Network identifiers** | client **IP** (login, requests), VM egress IP = host's **home IP** | request logs, Cloudflare, host | security; admins | **Legitimate interest** (security/abuse) | **security logs 90 d**, then delete or fully anonymize |
| **Support** | emails, tickets | (external mailbox / future) | support staff | Contract / legit. interest | **24 mo** after resolution |
| **Payments** | Mollie payment id, last4/method (**Mollie holds the card data, not Bunk**) | Mollie + a payment-ref row | billing | Contract + legal | invoice refs **7 y** |

### 1b. Fillable register template (one row per processing activity — copy into a sheet)

```
Verwerkingsactiviteit:        [e.g. "Klant-authenticatie"]
Verwerkingsverantwoordelijke: Bunk-Hosting (NL), [KvK], [contact/DPO]
Doel:                         [why]
Categorieën betrokkenen:      [tenants / host-operators / prospects]
Categorieën persoonsgegevens: [account / IP / VM-metadata / usage / ...]
Grondslag (Art. 6):           [contract / legit. interest / consent / legal obligation]
  - bij legit. interest:      [LIA-referentie / belangenafweging]
Ontvangers / verwerkers:      [Mollie, Cloudflare, host-operators, infra-provider]
Doorgifte buiten EER:         [ja/nee; zo ja: mechanisme (SCC/adequaatheid)]
Bewaartermijn:                [getal + trigger, zie schema hierboven]
Beveiligingsmaatregelen:      [encryptie, toegang, pseudonimisering, logging]
Bron van de gegevens:         [betrokkene zelf / afgeleid (IP) / host]
```

Minimum set of rows to fill: (1) Account & auth, (2) VPS provisioning & hosting, (3) Metering & facturatie, (4) Security/abuse logging, (5) Host-operator onboarding & payouts, (6) Betalingen (Mollie), (7) Support, (8) Website/Turnstile/analytics.

---

## 2. Lawful basis per category — and the split that keeps security logging off the consent path

The key engineering win: **separate your logs by lawful basis at write time**, so you never have to consent-gate security logging and you can delete analytics without touching security data.

| Data | Basis | Why / engineering consequence |
|---|---|---|
| Account, VPS lifecycle, metering→invoice | **Art. 6(1)(b) contract** | Needed to deliver the service. No consent needed. |
| Invoice/fiscal records | **Art. 6(1)(c) legal obligation** (NL 7-yr bewaarplicht) | Overrides erasure for those specific rows. Keep them in a separate `invoices` table you do **not** auto-purge. |
| **Security & abuse logs** (auth attempts, IPs, rate-limit hits, agent/command audit) | **Art. 6(1)(f) legitimate interest** | Do a short **LIA** (legitimate-interest assessment) once and reference it. **No consent.** This is the basis that lets you log a lot — *provided* it's genuinely for security and minimized + time-boxed. |
| Product analytics, marketing, non-essential cookies | **Art. 6(1)(a) consent** | Must be opt-in, granular, withdrawable. Keep this stream **physically separate** (different table/sink) so a withdrawal or a "reject all" simply stops/deletes that stream and never affects security logging. |
| Host-operator processing of tenant data | contract + **Art. 28 sub-processor** | The operator is a (sub-)processor; needs an agreement, not a consent. |

**Concrete rule to implement:** two sinks.
- `security_events` (basis: legit. interest, 90 d, pseudonymized IP) — auth, rate-limit, command/agent audit, provisioning actions.
- `analytics_events` (basis: consent, only written if consent cookie present) — page views, feature usage.
Never write a security event into the analytics sink or vice-versa.

---

## 3. The "lots of logs" tension — a concrete, defensible logging strategy

You can keep rich logs **and** be compliant if you do four things: minimize, pseudonymize, separate, and time-box.

**3.1 Data minimization.** Log the event and the *hashed* actor, not the raw identity, unless the raw value is the point (a security investigation may need the real IP for a short window). Strip request bodies/tokens. You already redact `password`/`totp_secret` in Ecto (`redact: true`) and `parseApiError` refuses to echo bodies — extend that discipline to logs.

**3.2 Pseudonymization / hashing of identifiers.** For IPs in *analytics/operational* logs, store `HMAC-SHA256(ip, rotating_daily_key)` so you can still count distinct actors and detect abuse patterns without storing the raw IP. Keep the **raw** IP only in the short-lived `security_events` store.

```elixir
# control_plane: a tiny pseudonymizer
defmodule ControlPlane.Privacy do
  @doc "Stable-per-day pseudonym for an IP; raw IP never leaves security_events."
  def pseudonymize_ip(ip) when is_binary(ip) do
    key = daily_key()                      # rotated key in app env / vault
    :crypto.mac(:hmac, :sha256, key, ip) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
```

**3.3 Separate security from analytics** — two sinks as in §2. Different retention, different basis, different access control.

**3.4 Hard retention schedule with auto-deletion.** Numbers I would defend for this platform (tune with your DPO):

| Log/stream | Retention | Rationale |
|---|---|---|
| Auth/security events (raw IP) | **90 days** | long enough for incident response/abuse, short enough to be proportionate |
| Request/access logs | **30 days** raw, then pseudonymized aggregate or delete | ops debugging window |
| Agent/command audit (provision/delete/power) | **180 days** | disputes about VM lifecycle / operator behavior |
| Raw per-VM metering rows | **90 days** raw → roll up to monthly aggregates | aggregates are not personal once owner-stripped |
| Invoices / fiscal | **7 years** | NL fiscale bewaarplicht (legal obligation) |
| Analytics (consented) | **14 months** max | matches common analytics norms; deletable on withdrawal |
| Backups | **35 days** rolling | bounds the "erasure vs backup" problem (§4) |

**Implement auto-deletion as a scheduled job** (you already have a `Reconciler` GenServer running every 30 s — add a daily retention sweep):

```elixir
# runs daily; bounded, indexed deletes
def purge_expired do
  cutoff = DateTime.add(DateTime.utc_now(), -90 * 86400, :second)
  Repo.delete_all(from e in "security_events", where: e.inserted_at < ^cutoff)
  Repo.delete_all(from u in "usage_records", where: u.metered_at < ^cutoff and u.rolled_up == true)
  # invoices table deliberately excluded
end
```
(Add a partial index on the timestamp columns so these stay cheap — mirrors the `usage_records(metered_at)` index already added.)

---

## 4. Data-subject-rights flows (Art. 15–17, 20)

Design these as authenticated dashboard endpoints + an async job, because erasure has to reach Postgres **and** the worker host **and** be reconciled against backups.

| Right | Endpoint | Behavior |
|---|---|---|
| Access / portability (15/20) | `GET /api/v1/me/data-export` | async job assembles a JSON/ZIP: account, VPSes, usage, invoices, security events *about them*; emailed as a signed, expiring link. Machine-readable = portability satisfied. |
| Rectification (16) | existing profile edit + `PATCH /api/v1/me` | name/email; email change re-verifies. |
| Erasure (17) | `POST /api/v1/me/delete` | see flow below. |

**Erasure flow (the hard one — interacts with backups, logs, fiscal data, and the host):**

1. **Immediate:** soft-delete account; revoke all `user_tokens`; **issue `delete` commands to every node hosting their VPSes** so the VM (and its disk) is destroyed on the host — *this is the step most providers forget; the tenant's data is on a third party's disk.* Confirm destruction via the agent result.
2. **Crypto-shred** any tenant-supplied secrets (console keys) and overwrite the VM's disk on the host (agent should `discard`/zero the volume, not just `qm destroy`).
3. **Pseudonymize, don't delete, the rows you must keep:** replace `owner_email` with a tombstone (`deleted-<uuid>@invalid`) in `invoices`/fiscal `usage_records` so the 7-yr obligation is met without retaining identity beyond purpose. Everything not legally required → hard delete.
4. **Backups:** you cannot surgically delete from immutable backups. Document this: backups roll off in **35 days** (§3.4) and are not restored selectively; if a restore happens, a re-apply of the deletion log re-erases. State this in the privacy policy.
5. **Security logs:** keep (legit. interest) but they age out at 90 d; pseudonymize the actor there too.

Build a `deletion_log` table so a backup-restore can replay erasures (point 4).

---

## 5. The distributed-hosting problem (the part that's actually novel)

### 5.1 Are the home hosts sub-processors? — **Yes.**
A host-operator processes tenant personal data (the VM, its contents, the tenant's egress traffic) **on Bunk's behalf and on Bunk's instructions** (the scheduler tells them what to run). That makes each operator an **Art. 28 sub-processor**. Consequences:
- They must accept a **sub-processor / host agreement** *before* a node can receive its first VPS. **Gate it in the onboarding flow** — the new `POST /api/v1/host/activate` is the natural enforcement point: do not promote to operator (or do not let `create_enroll_token` succeed) until a versioned host-DPA is accepted and recorded.
- The agreement must bind them to: process only on instruction, confidentiality, Art. 32 security measures, no access to tenant VM data, breach notification to Bunk within X hours, deletion on instruction, and submit to audit.
- Maintain a **public sub-processor list** (even if pseudonymous: "community hosts in NL/DE", with a notification mechanism for changes — Art. 28(2)).

```elixir
# host_controller.ex — refuse activation without accepted host-DPA
def activate(conn, %{"dpa_version" => v}) when v == @current_host_dpa do
  # record acceptance (user_id, version, ip, ts) then promote
end
def activate(conn, _), do: conn |> put_status(:unprocessable_entity) |> json(%{error: "host_agreement_required"})
```

### 5.2 Data residency — keep EU tenant data on EU hosts, let tenants pick.
You already have a **`regions`** concept (`nl-1`) and the scheduler honors `region_id`. Use it as the residency control:
- Tag every node with a **verified** country (operator-claimed country is untrusted — corroborate with the node's observed IP geolocation at enroll/heartbeat, and flag mismatches).
- Constrain the scheduler to **only place a tenant's VPS on nodes whose region ∈ tenant's allowed residency set**. Expose a residency picker at VPS-create (default: EU-only).
- Block scheduling to a non-EU node for an EU-residency VPS at the reservation step (hard fail, not best-effort).

### 5.3 What you must disclose to tenants.
Plain-language, in the dashboard at VPS-create and in the policy: *that their VM runs on independent third-party "community" hardware, that the host has physical control of the machine, what Bunk does to mitigate (encryption, isolation), the country it will run in, and that they should treat the VM like any VPS (encrypt sensitive data themselves).* See Dutch snippet in §7.

### 5.4 Security-of-processing on a hostile host (Art. 32) — engineering musts.
- **Encrypt tenant disks at rest with a key the host operator does not hold** (e.g. per-VM LUKS keyed from the control plane / tenant, unsealed at boot over the authenticated channel) so a host pulling the disk gets ciphertext. *Today this is a gap (G9).*
- **Network isolation** between co-tenant VMs (you already have per-tenant VPS bridges + firewall zones per the infra notes — verify tenant↔tenant is blocked).
- Treat the worker as untrusted: see the security report (resource-lying, command replay, the WireGuard overlay RCE) — those are also *privacy* controls, because a compromised host = tenant data breach.

---

## 6. Processors & the DPAs you need

| Third party | Role | Document needed | Note |
|---|---|---|---|
| **Mollie** | Payment processor (NL) | **DPA** (Mollie offers a standard one) | Mollie holds card data → smaller scope for you; still list them. *Note: no Mollie integration exists in the code yet — add the DPA when you wire it.* |
| **Cloudflare** | TLS termination + tunnel + WAF — **sees all traffic and client IPs** | **DPA + SCCs** (US entity; EU SCCs / DPF) | Currently load-bearing: it terminates TLS for `app.bunkhosting.nl`. This is a real processor with broad visibility — must be in the register and have SCCs. |
| **Host-operators** | Sub-processors (§5.1) | **Host-DPA** | The novel one. |
| **Infra/hosting** (the Proxmox host provider, if not self-owned) | Processor | DPA | If you own the hardware, n/a. |
| **Email/support provider** | Processor | DPA | When added. |
| Error/telemetry SaaS (if any) | Processor | DPA + minimization | The frontend has an `observability.ts` reporter — confirm where it sends and DPA that sink. |

---

## 7. Cookie/consent + privacy policy (dashboard)

**Cookies in use today (from the code):** `access_token=1` presence marker (strictly necessary — no consent needed), Cloudflare Turnstile (`challenges.cloudflare.com` — security/anti-bot, strictly-necessary basis is defensible), `bunk_token` in localStorage (strictly necessary). **No analytics cookies found** — so today a **strictly-necessary-only banner** suffices, but the moment you add analytics you need a real consent manager.

**What to ship:**
- A consent banner that distinguishes **strictly necessary** (always on, no toggle) from **analytics/marketing** (default off). Don't load any analytics script before opt-in.
- A `/privacy` and `/cookies` page linked from the dashboard footer and the register page.

**Dutch user-facing snippets (verify with a lawyer):**

> **Cookies.** Bunk Hosting gebruikt alleen strikt noodzakelijke cookies om je ingelogd te houden en de dienst te beveiligen (waaronder Cloudflare Turnstile tegen misbruik). Deze zijn nodig om het platform te laten werken en kun je niet uitschakelen. We plaatsen pas analyse- of marketingcookies nadat je daar expliciet toestemming voor hebt gegeven.

> **Jouw VPS draait op onafhankelijke hardware.** Een deel van onze capaciteit draait op hardware van community-leden ("hosts"), niet in een klassiek datacenter. Dat betekent dat de fysieke machine waarop jouw VPS draait wordt beheerd door een derde partij. Bunk verplicht elke host tot een verwerkersovereenkomst, isoleert VPS'en van elkaar en versleutelt schijven. Behandel je VPS zoals elke server: versleutel zelf gevoelige gegevens. Je kunt bij het aanmaken kiezen in welk land (EU) je VPS draait.

> **Bewaartermijnen.** Accountgegevens bewaren we zolang je een account hebt en daarna maximaal 90 dagen. Facturen bewaren we 7 jaar (wettelijke fiscale bewaarplicht). Beveiligingslogs bewaren we maximaal 90 dagen. Je kunt je gegevens inzien, exporteren of laten verwijderen via je dashboard.

---

## 8. DPIA (Art. 35) — you very likely need one

Two Art. 35 triggers fire: **large-scale systematic monitoring** (the "lots of logs" + abuse detection) and **innovative use / novel technology** (hosting tenant data on uncontrolled third-party home hardware). Run a DPIA before scaling. Engineering inputs are already in §1/§5; the residual-risk items are G2, G5, G9.

---

## 9. Prioritized remediation list (tickets)

**P0 (do first)**
1. **Retention + auto-deletion job** (§3.4): add `security_events`/`analytics_events` split + a daily `purge_expired` sweep + timestamp indexes. Stops indefinite retention (G1).
2. **Host-DPA gate** in `host_controller.activate` / enroll-token mint (§5.1): no node onboards without accepting a versioned sub-processor agreement, recorded (G2).
3. **Verwerkingsregister**: fill the §1b template for the 8 activities (G3).
4. **DSR flows**: `me/data-export`, `me/delete` (with host VM destruction + disk wipe + fiscal-row pseudonymization + `deletion_log`) (G4).

**P1**
5. **IP pseudonymization** + raw-IP confined to `security_events` (§3.2) (G5).
6. **DPAs/SCCs**: Cloudflare (now), Mollie (when added), any telemetry sink (G6).
7. **Consent layer + /privacy + /cookies** with the strictly-necessary/analytics split (G7).
8. **DPIA** for the distributed model (G8).
9. **At-rest tenant-disk encryption keyed away from the host** (G9) — also a security control.

**P2**
10. Residency enforcement in the scheduler (EU-only default) + verified node geolocation (§5.2).
11. Operator transparency UI + sub-processor list page.
12. Breach-notification runbook (72-h controller notification; host→Bunk SLA in the host-DPA).

---

## 10. Questions to take to a lawyer / DPO

1. Is the **host-operator** a sub-processor (my engineering read: yes) or an independent controller for anything they do on their own box? This changes the agreement type.
2. Do we need a **DPIA** formally, and does the distributed model require **prior consultation** with the Autoriteit Persoonsgegevens (Art. 36)?
3. Are the **retention numbers** in §3.4 defensible (esp. 90 d security logs, 7 y invoices, 35 d backups)?
4. Is **legitimate interest** sound for all security/abuse logging, and is a documented LIA enough?
5. For **non-EU hosts**: are SCCs + technical residency controls sufficient, or must we hard-prohibit non-EU placement for EU tenants?
6. What exactly must we **disclose** about third-party home hosts to satisfy Art. 13 transparency — is the §7 snippet enough?
7. Is **Cloudflare** TLS-termination an international transfer needing SCCs, given it sees plaintext + IPs?
8. Liability allocation if a **host-operator breaches** (reads/leaks tenant data) — controller vs sub-processor responsibility.
9. Is **Turnstile** strictly-necessary (no consent) or does it need consent?
10. Do **operators** (whose home IP and payouts we store) get the same DSR rights, and how does that interact with our need to keep payout/fiscal records?
