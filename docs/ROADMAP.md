# Bunk Hosting — Product & Technical Roadmap

*Written as the engineering lead. Bunk is a **multi-node VPS provider running its
own capacity**. Customers register, pay with Mollie, and get an automatically
provisioned VPS placed by the control plane onto one of our nodes. Customers
never operate a node and never see the fleet.*

---

## 0. The pivot, and what it costs us

The original plan was federated: customers would run a node at home and earn back
part of their own bill. That is dropped — it does not survive contact with trust,
uptime, liability and payout. The consequence runs through everything below:

> **There is no free crowd capacity. Every euro of price has to clear our own
> hardware, power and transit cost.**

The good news is that it does clear, with room. The bad news is that it removes
the only story we had that Hetzner and Contabo can't copy, so §4 (positioning) is
now the real open question, not the engineering.

## 1. Where we actually are

**Works today:** control plane + Next.js dashboard, registration/login + 2FA,
VPS lifecycle (create/start/stop/delete) with real automatic provisioning on
**Proxmox and ESXi/vCenter**, owner-scoped and race-safe authorisation, a prepaid
**credit wallet**, **Mollie top-ups** (fetch-to-verify, idempotent webhook),
per-VPS **subscriptions** with recurring billing, an SSH console with host-key
pinning, a WireGuard overlay, and an admin panel (users, VPSes, nodes, node
delete).

Phase 1 of the old roadmap — "a stranger can pay and get a VPS" — is **done**.

**The one gap that still blocks selling: backups.** See §3.

## 2. Cost model — what a node actually costs

RAM is the binding resource. vCPU overcommits 3–4:1 safely; RAM realistically
does not, so *cost per sellable GB of RAM per month* is the master number.

Reference node: second-hand 2× Xeon E5-2680v4 / 256 GB / 8× 1.92 TB SSD,
≈ €1200 amortised over 4 years, ~180 W, 16 GB hypervisor overhead, 75% average
occupancy.

| | at home (€0.28/kWh + €50 business line) | 1U colo (€60/mo incl. power + transit) |
|---|---|---|
| fixed cost/month | €111.77 | €85.00 |
| **per sellable GB RAM** | **€0.62** | **€0.47** |
| full node (30× Pro), revenue | €450 | €450 |
| all-in cost incl. IPv4, backup, Mollie, tooling, failure reserve | €182 | €155 |
| margin | €267 (59%) | €294 (65%) |
| break-even occupancy | 41% | 35% |

**Colocation beats hosting at home.** Consumer electricity plus a dedicated
business line costs more than a €60 1U slot with power and bandwidth included —
and colo also buys the uptime, transit quality and IP reputation that a home line
cannot give a paying customer. Put the nodes in colo.

Current catalogue against that floor (colo):

| package | cost incl. IPv4 | price | margin |
|---|---|---|---|
| Starter 1/1/20 | €1.22 | €3.99 | 3.3× |
| Basic 2/2/40 | €1.69 | €7.99 | 4.7× |
| Pro 4/8/80 | €4.53 | €14.99 | 3.3× |
| Business 8/16/160 | €8.31 | €29.99 | 3.6× |

Every package clears its floor. The prices are defensible on cost.

## 3. Backups — draaien; off-node is uitgesteld

**Wat werkt.** Twee onafhankelijke ketens, allebei geverifieerd.

*Klant-VPSen:* `vzdump`-snapshot, dagelijks automatisch plus op verzoek, retentie
op aantal, en terugzetten — via de `backup`, `delete_backup` en `restore_backup`
commandosoorten. Bewezen met een archief van 1,4 GB in 97 s en een restore die een
markeerbestand liet verdwijnen. Terugzetten vergeet ook de gepinde SSH-hostsleutel,
want de oudere schijf draagt een oudere sleutel en TOFU zou dat anders als aanval
lezen en de klant buitensluiten uit de console waarmee hij net kwam kijken.

*Control plane:* dagelijks een versleuteld archief met de database, `.env.prod` en
een manifest, geduwd naar de Proxmox-host. Versleuteling is asymmetrisch — alleen
het certificaat staat op VM102, de private sleutel is nergens nodig om een back-up
te máken. Op 2026-09-14 end-to-end nagekeken: het archief van die ochtend
ontsleutelt, het manifest noemt het juiste commit en migratienummer, en
`pg_restore --list` leest er 18 tabellen met data uit.

**Off-node: uitgesteld, bewust.** Stijn heeft op 2026-09-14 besloten dat de
back-ups voorlopig op de host blijven. Later mogelijk een server elders, met
synchronisatie over een VPN.

Wat dat betekent, zodat het een keuze blijft en geen vergissing: de archieven
overleven een kapotte VM en een verwijderde VPS, maar niet het verlies van de
machine zelf. Brand, diefstal of een dode schijfcontroller neemt de VPSen en hun
back-ups tegelijk mee. Voor een platform zonder betalende klanten is dat een
verdedigbare afweging; het wordt er een om te herzien zodra er iemand betaalt.

**Het scherpste dat nu nog openstaat is niet de opslag maar de sleutel.** VM102
draagt zowel het pushkredentiaal naar de host (`/etc/bunk-backup/id_ed25519`) als
de private sleutel die de archieven ontsleutelt (`/etc/bunk-backup/backup.key`).
Wie VM102 heeft, heeft daarmee elke back-up leesbaar — precies de scheiding die de
asymmetrische opzet wilde aanbrengen. `backup.key` van VM102 af halen kost
operationeel niets: back-ups maken gebruikt hem niet, alleen `restore.sh`, en dat
is een bewuste handeling.

## 4. Positioning — the actual open question

We sit 2–3× above the big providers on raw specs (Hetzner CPX11 2/2/40 at €4.35
vs our Basic at €7.99; Contabo VPS S 4/8/200 at €5.36 vs our Pro at €14.99). We
will never win on price against operators with their own datacenters and six
figures of servers.

So the price has to buy something they don't sell. Candidates, in order of how
credible they are for us:

1. **Dutch, reachable, human support.** A named person who answers in Dutch,
   same day. Hetzner and Contabo do not.
2. **Managed, not just rented.** Backups on by default, monitoring included,
   patching and restore handled — priced as a service, not as a slice of a
   server.
3. **A niche that needs hand-holding.** Dutch SMEs, agencies reselling hosting,
   or education — buyers for whom €8 vs €4 is irrelevant next to "someone picks
   up the phone".

This is a business decision, not an engineering one, and it determines whether
the roadmap below should aim at *cheaper* or at *more managed*. Current
recommendation: **more managed** — it matches the cost structure (we have margin
to spend on service) and it is the only one of the three that scales.

## 5. Fleet operations — what running >1 node needs

- ~~**Node drain / maintenance mode.**~~ **Done.** `POST /beheer/nodes/:id/drain`
  closes a node to new VPSes while everything on it keeps running and keeps being
  served; `/resume` reopens it. Proven by draining the live node and watching the
  scheduler stop placing on it. What is still missing is the step after: moving
  the VPSes off, which needs the cross-node restore from §3.
- **Restart-elsewhere on node failure.** From the last backup (RPO = last
  snapshot), clearly disclosed. Not live migration — that is a multi-quarter
  effort and not warranted yet.
- **Per-node cost reporting.** `Billing.resource_cost_summary/1` already
  aggregates resource-hours per node cost centre. Point it at the real per-node
  cost from §2 so we can see margin per node, not just fleet-wide.
- **Capacity planning.** Alert when fleet-wide free RAM drops below the headroom
  needed to survive losing one node.

## 6. Platform polish

VPS reboot / rebuild / resize · noVNC console (SSH bridge exists) · snapshots UI
· SSH-key management · firewall / security groups · monitoring graphs and
alerting · bandwidth metering and quota.

## 7. Open decisions

1. **Colo or home?** §2 says colo. Needs a provider and a budget line.
2. **Backup storage:** self-hosted MinIO (cheaper, more ops) vs Backblaze B2
   (easy, small cost). Recommendation: B2 to start, MinIO when volume justifies.
3. **Positioning (§4):** cheaper, or more managed? This gates §6's priorities.
4. **Real hardware numbers.** §2 runs on a reference spec. Replace it with the
   actual machines, purchase prices, power tariff and transit cost to make the
   pricing defensible rather than plausible.
