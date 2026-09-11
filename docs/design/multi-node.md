# Design — one control plane, many resource nodes, several regions

*Status: proposal. Written 2026-09-12 against commit `d987b4c`. Every "today"
claim below was verified against the live system, not inferred from the code.*

The target: one control plane; multiple resource nodes carrying customer VPSes;
nodes grouped into regions; a customer may state a region preference, and when
they don't, the platform places the VPS on a node that has room. Customers never
see a node.

That is the right shape, and the codebase is already built for it. The work is
not a redesign. It is closing a small number of gaps, in an order that matters
more than the gaps themselves.

---

## 1. Where we actually are

### 1.1 It is one physical machine

Everything runs on `CP-NL1-01`:

| | |
|---|---|
| VM 102 | control plane, Postgres, frontend, edge |
| VM 106 | **a running customer VPS** |
| VM 100 | the router (OpenWRT) — gateway for the VPS network |
| LXC 103 | the Cloudflare tunnel |
| LXC 104 | the marketing site |
| LXC 101 | the worker agent that manages the nodes |

One disk, one PSU, one kernel panic and all of it goes at once: control plane,
database, router, tunnel, website, and the customer's server.

This matters more than it looks. The architecture separates control plane from
data plane correctly — the agent is autonomous, VPSes survive a control-plane
restart — but **that separation does not exist physically**. "VPSes keep running
when the control plane is down" is true of the code and false of the deployment.

Everything else in this document is downstream of that.

### 1.2 The fleet

One region, `nl-1`. Two nodes, both in it:

- `node-7p04lMHBqk0` (Proxmox, online): 4 vCPU / 11.8 GB / 93 GB, of which
  **1 vCPU, 8.7 GB and 33 GB are free**
- `node-o0-9YLe_NZY` (ESXi): offline since 10 July

One active VPS, one stopped, three accounts.

The online node cannot fit a Pro (4/8/80) — there is 33 GB of disk left. Of the
four packages on sale, exactly one more Starter can be delivered. The catalogue
is ahead of the hardware.

The cost model in `ROADMAP.md` (€0.47–0.62 per sellable GB RAM) assumes the
reference machine: 2× Xeon, 256 GB, 8× 1.92 TB. On the current box those numbers
do not hold, because the fixed cost is spread over a fraction of the capacity.

### 1.3 A customer cannot reach their own VPS

This is the largest finding in this document, and it is an infrastructure fact
rather than a missing feature.

The network, as deployed:

| bridge | what | uplink |
|---|---|---|
| `vmbr0` | LAN, `192.168.1.0/24`, gateway `192.168.1.1` (the ISP router) | physical NIC |
| `vmbr1` | management, `192.168.10.0/24` — control plane, tunnel | none |
| `vmbr2` | **the customer VPS network**, `10.10.0.0/19` | **`bridge-ports none`** |

The Proxmox host carries exactly one address — `192.168.1.70/24`. There is no
public address anywhere on it. `vmbr2`, the bridge every customer VPS sits on,
has no physical uplink at all; the OpenWRT VM straddles all three bridges and
NATs VPS traffic outbound through the LAN to the ISP router.

So a customer VPS can reach the internet, and nothing on the internet can reach
it. The only public ingress to the whole estate is the Cloudflare tunnel, which
serves the web app over HTTP — not raw SSH to a customer's machine.

Meanwhile `vpses.ip_address` holds `10.10.0.20`, `10.10.0.21`, and the dashboard
hands the customer that address as their SSH endpoint, port 22, user `root`. It
is unroutable from anywhere outside this one Proxmox host.

There is also no public-IP concept in the control plane — no allocation, no
floating IP, no port-forward, no DNAT — so even if the upstream router were
forwarding ports by hand, the platform would neither know about it nor be able
to hand a second customer a second port.

What this means: **the product as deployed cannot deliver what a VPS is.** No
SSH from outside, no website, no game server, nothing a buyer would assume. The
browser console is the only way in, and it runs through the control plane.

It also explains a hole in the cost model: `ROADMAP.md` budgets €0.75/month per
IPv4, and there are none.

This outranks everything else here, including the single-chassis problem in §1.1.
A machine that no customer can connect to does not become sellable by being made
redundant.

### 1.4 No backups

Still true, still the blocker for selling. A VPS disk lives on the node it runs
on; if the node dies, so does the data.

---

## 2. What already works, and should not be touched

Worth stating plainly, because the gap list below is long and could read as if
the foundation were weak. It isn't.

- **Placement is genuinely capacity-aware.** `Fleet.Scheduler.place/2` filters to
  online nodes in the requested region that fit, locks the candidate rows
  `FOR UPDATE` in a deterministic order (deadlock-safe), scores by headroom
  remaining after placement, decrements capacity and records a reservation — all
  in one transaction. Two concurrent placements cannot oversell a node.
- **Region filtering exists already.** The scheduler takes `region_id` and only
  considers nodes in it. The gap is that nothing lets the customer *choose*; see
  §3.1.
- **The agent dials out and is autonomous.** No inbound ports on nodes, and a
  control-plane outage does not stop VMs.
- **The overlay is management-only.** WireGuard is hub-and-spoke with the control
  plane as hub, used for the console and CP→node access. Customer traffic egresses
  via the node's own uplink. A hub outage costs consoles, not customer traffic —
  a distinction that would have been expensive to retrofit.
- **Nodes already carry their own network.** `vps_gateway`, `vps_cidr_prefix`,
  `vps_range_start`, `vps_range_end` are per-node, and `IpPool.allocate/1`
  receives the chosen node — placement happens first, addressing second. The
  ordering a second site needs is already right.

---

## 3. The gaps, in the order they should be closed

### 3.0 Get onto a second physical machine

Nothing else on this list is worth doing first. While the control plane, the
database, the router and the customer VPS share a chassis, resilience work is
decoration: any failure that the work would protect against takes the protected
thing with it.

The first split is also the cheapest one. Move the control plane and Postgres off
the box that carries customer workloads — a small external VM is €5–20/month.
That alone converts "everything dies together" into "the control plane and the
node fail independently", which is the premise the whole architecture already
assumes.

Only after that does a second *resource* node make the fleet meaningfully bigger.

### 3.1 Let the customer choose a region

Smaller than it sounds. The backend already places per region; the frontend sends
`region_code: "nl-1"` hardcoded in `src/lib/api.ts`.

What is missing: a public endpoint listing selectable regions, a picker in the
order flow, and — the part worth thinking about — what "no preference" should
mean. Proposal:

- The customer picks a region, or picks "no preference".
- With no preference, the platform picks the region with the most free capacity,
  which is also what keeps the fleet balanced without any explicit balancing.
- A stated preference is a **constraint, not a hint**: if the chosen region is
  full, the request fails with a clear message rather than silently landing the
  VPS in another country. Data residency is a promise; quietly breaking it to
  satisfy an order is the wrong trade.

### 3.2 Public addressing

Needs a decision before it needs code (§6). Once decided, the shape is:

- Addresses are a **per-region resource**, because they come from whatever uplink
  that site has. Model them as a pool per region (or per node), allocated at
  provision time alongside the private address, released on delete.
- The same table answers "how many can we still sell here", which the placement
  logic in §3.5 then has to respect: a region with capacity but no free addresses
  is full.

### 3.3 Backups

The one feature that blocks selling, unchanged from the roadmap: off-node,
encrypted, scheduled, with a restore that has actually been run. Restore to a
*different* node is also the cheapest failover story available at this size —
worth designing for from the start even if it is operated manually at first.

### 3.4 The IP pool is not scoped to a network

`IpPool.used_ips/2` collects every VPS address in the system and filters by
numeric range. That is correct only while every node uses a distinct range — but
the *default* range is the same for every node.

Two nodes on that default share one address pool: no duplicates (the filter sees
them), but the pool exhausts fleet-wide instead of per network, and two isolated
L2 segments that could each legitimately use `10.10.0.20` are treated as one flat
network. It breaks the day a second node enrols with default settings, and
nothing currently documents that each node needs a unique subnet.

Fix: scope allocation to the node's own network rather than to a numeric window
over the global table.

### 3.5 Scheduler: what to add, and what not to

Today's scoring — most headroom after placement — spreads load. For a small
fleet that is the right default: it leaves room for growth and limits how much a
single node failure takes down.

Worth adding, in this order:

1. **Node drain.** A node marked draining takes no new placements. Needed the
   first time hardware has to be patched, which is well before ten nodes. Cheap:
   one status value, one clause in `lock_candidates/2`.
2. **Per-owner anti-affinity.** A customer with several VPSes should not lose all
   of them to one failed node. Cheap as a tiebreak: prefer a node that carries
   none of that owner's VPSes.
3. **Region-level capacity for the "no preference" path** (§3.1).
4. **Explicit overcommit policy.** vCPU is safely oversubscribed; RAM in practice
   is not. Make the ratio configuration rather than an implicit property of how
   capacity is reported, so it can be tuned per node generation.

Deliberately **not** now: a pluggable scoring framework, bin-packing modes, live
migration. One node and three accounts do not justify them, and each would have
to be redesigned once there is real data about how the fleet is actually used.

### 3.6 Prepare for a second control plane without building one

The control-plane-HA research is unambiguous: the industry does not make the
control plane highly available, it makes it unimportant. Hetzner's own incident
notices say running servers are unaffected while the API is down for hours;
DigitalOcean's Droplet SLA does not mention the API at all; Fly.io moved *away*
from central consensus. Automatic Postgres failover needs three voting members
plus fencing, not one extra VM — at this size it lowers availability rather than
raising it.

So: do not build it. But four things are cheap now and are a rebuild later:

1. **Leader election around singleton work** (reconciler, metering tick, cron).
   One Postgres advisory lock behind a single abstraction. Today it always wins;
   the day a second instance starts, it is already correct.
2. **Idempotent, at-least-once commands.** Every command carries a key and
   tolerates redelivery. Moves the agent protocol towards desired-state
   reconciliation, where a lost or doubled message is self-healing instead of a
   wedged VPS.
3. **Expand/contract migrations.** Each migration backwards-compatible with the
   previous release — the precondition for ever running two versions at once.
4. **A console path that does not depend on the control plane.** Documented
   break-glass access, so a customer with a broken VPS during a CP outage is not
   locked out entirely.

### 3.7 Secrets and restore

`.env.prod` holds `ADMIN_TOKEN`, `SECRET_KEY_BASE` and the `CONSOLE_SSH` keypair.
Lose it and a database restore is not enough: without the console key there is no
way back into existing customer VPSes.

The backup I took during the tier migration currently sits on VM 102 — the same
VM as the control plane, so it is not a backup at all. It needs to be encrypted
and held off-machine, and the restore needs to have been rehearsed once with the
elapsed time written down. An untested restore is a hope, not an RTO.

---

## 4. What a second region actually requires

Collecting the above, adding a region is not a control-plane change. It is:

- a node in that location, with its **own uplink, gateway and unique private
  range** (already modelled per node — §2)
- **address space for that site** (§3.2), since customer-reachable addresses come
  from the local uplink
- a `regions` row, and the region exposed for selection (§3.1)
- the overlay reaching that node — works today, but every node's management
  traffic hairpins through the hub, which is worth revisiting once nodes are far
  apart
- a decision about **where that region's backups live** — same region keeps the
  residency promise simple, elsewhere survives losing the site

Notably absent: nothing in the scheduler, the billing, or the agent protocol has
to change to support a second region. That part is genuinely done.

---

## 5. Order of work

**First — make the VPS reachable.** Until a customer can connect to what they
bought, nothing else on this list changes whether the product can be sold. This
needs an uplink that carries public addresses: a colocated machine with routed
space, or a provider that hands out addresses per server. It is a hosting
decision before it is a code decision, and §6.1 is the fork.

**Then — stop sharing a chassis.** Control plane and Postgres onto their own
machine. Encrypted off-host copy of `.env.prod`. One rehearsed restore with a
measured time. In practice this probably falls out of the move above: the
machine that gets a real uplink is unlikely to be the one under a desk.

**Then — ship backups.** The remaining thing standing between this and taking a
paying customer seriously.

**Then — make the fleet real.** A second resource node on proper hardware, the
per-network IP fix, node drain, region selection in the UI.

**Alongside, because it is cheap now and expensive later** — leader election,
idempotent commands, expand/contract migrations, the break-glass console path.

**Not yet** — Postgres replication, automatic failover, shared or replicated
storage, live migration, regional control planes. Each has a scale at which it
starts paying for itself, and the fleet is one to two orders of magnitude below
all of them.

---

## 6. Decisions needed before code

1. **Where does the public address space come from?** No longer "do customers get
   a public IPv4" — §1.3 settles that they currently cannot, because the estate
   has no public address and the VPS bridge has no uplink. The open question is
   which route out of that: colocation with a routed subnet (a /29 or larger, so
   the platform allocates from a pool per site), a provider that assigns an
   address per machine, or an IPv6-first offering with shared IPv4 ingress. Each
   implies a different model in §3.2 and a different promise to the customer.
   Everything else waits on this.
2. **Where does the control plane move to?** Own hardware at a colo, or a small
   VM at another provider. The second is faster and cheaper; the first keeps
   everything under one roof.
3. **Which regions, and why?** A second Dutch site is a different product promise
   (redundancy) than a German or Nordic one (latency, residency). The answer
   shapes what to tell customers the choice is *for*.
4. **Backup target**: self-hosted object storage versus a provider. Trade-off is
   cost and control against one less thing to run.
5. **Still open from the pivot**: cheaper, or more managed? It has not moved, and
   it decides whether the effort after this goes into automation or into service.
