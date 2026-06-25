# Architecture & Roadmap

Bunk Fleet powers a **federated** VPS hosting platform: a central control plane
orchestrates worker nodes that operators contribute from their own
Proxmox/Incus machines, anywhere in the world.

## The four problem layers

1. **Compute** — actually creating, running, and destroying VMs on heterogeneous
   operator hardware behind NAT, across hypervisors (Proxmox, Incus).
2. **Scheduling** — deciding *where* a customer's VPS runs: honoring the
   user-chosen region and packing onto the node with the most free capacity.
3. **Connectivity + trust** — giving VPS instances routable public endpoints
   despite operator NAT, and bounding the blast radius of untrusted,
   operator-run nodes.
4. **High availability** — keeping the control plane and the fleet running
   through node failures and control-plane restarts.

## Chosen stack

| Concern               | Choice                          | Why                                                              |
| --------------------- | ------------------------------- | --------------------------------------------------------------- |
| Control plane         | **Elixir / Phoenix (OTP)**      | Massive concurrent flaky-agent connections, realtime console mux, supervision/fault-tolerance. |
| Worker agent          | **Go (stdlib-only)**            | Single static binary, trivial to ship to operator nodes.        |
| Hypervisors           | **Proxmox** + **Incus**         | Cover datacenter VMs and lightweight community nodes.           |
| Overlay networking    | **NetBird / WireGuard**         | NAT-traversing, encrypted overlay for VPS public endpoints.    |
| Persistence           | **Postgres** (via Ecto)         | Authoritative inventory, placement, and billing state.         |
| Secrets               | **Vault**                       | mTLS CA material, node creds, payout/billing secrets.          |

## Trust-tier model

- **Datacenter (trusted).** Vetted, professionally-operated nodes. Eligible for
  all workloads; minimal restrictions.
- **Community (lower trust).** Operator-run nodes. Gated by **reputation** and a
  financial **deposit**; placement and workload sensitivity are constrained.
- **Future: confidential computing** lets even untrusted community hosts run
  sensitive workloads without the operator being able to inspect them.

Tier is assigned at enrollment, carried in the node's mTLS identity, and is a
first-class input to scheduling.

## Scheduling: region + resources

The customer **picks a region**. The control plane filters to healthy nodes in
that region whose `trust_tier` admits the workload, then places the VPS on the
node with the **most available resources** (vCPU/RAM/disk from the latest
heartbeat). Capacity is reserved against the node on placement and reconciled
against subsequent heartbeats.

## Overlay networking

VPS instances join a **WireGuard** overlay managed by **NetBird**. Because every
node and VM dials out into the overlay, the platform can assign **public
endpoints** and route east-west traffic between VPS instances regardless of the
operator's local NAT or firewall — no inbound port-forwarding on operator
networks is required. Public ingress for a VPS is anchored in the overlay rather
than on the operator's raw uplink.

## Failure modes

- **Node offline** (channel drops / heartbeats go stale) → the control plane
  marks the node offline, **drains** its scheduling eligibility, and
  **reschedules** affected/pending VPS instances onto other nodes in the region.
- **Agent crash / restart** → agent reconnects with its durable mTLS identity
  and **reconciles** running VMs against the control plane's expected state
  (heartbeat `running_vms` vs inventory).
- **Control-plane restart** → OTP supervision restarts processes; node channels
  reconnect with backoff; Postgres remains the source of truth so no placement
  state is lost.
- **Capacity drift** → heartbeats continuously correct the scheduler's view of
  available resources.

## Phased roadmap

- **F1 — Node-aware refactor.** Model nodes, regions, capacity, and placement in
  the control plane; make the schema and scheduler node-aware.
- **F2 — Agent + enrollment.** Ship `bunk-agent`; implement one-time-token
  enrollment, mTLS identity, the persistent channel, and heartbeats.
- **F3 — Incus + overlay + console.** Add the Incus provider, NetBird/WireGuard
  overlay for VPS endpoints, and end-to-end console multiplexing.
- **F4 — Operator economy.** Operator onboarding, billing, reputation/deposit,
  and payout flows for community nodes.
- **F5 — Control-plane HA.** Highly-available control plane with **Vault
  auto-unseal** and resilient secret management.
