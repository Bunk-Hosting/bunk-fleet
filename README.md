# Bunk Fleet

## Repository layout (monorepo)

This repository is the single home for the whole Bunk Fleet platform:

| Path | Component | Stack |
|------|-----------|-------|
| `control_plane/` | Control plane (API + scheduler + billing) | Elixir / Phoenix |
| `agent/` | Worker-node agent (provisions VMs, heartbeats, runs commands) | Go (Proxmox + ESXi) |
| `frontend/` | Customer dashboard | Next.js / TypeScript |

The frontend talks to the control plane via `/api/v1` (bearer auth); the agent
dials out to the control plane (enroll → heartbeat → command long-poll → result).
See each subdirectory's README for build/deploy details.


Bunk Fleet is the orchestration monorepo for **Bunk Hosting**, a multi-node VPS
platform. A central **control plane** schedules and manages a fleet of
**worker nodes** — all Bunk's own hardware — and exposes customer VPS instances
over a WireGuard overlay. Customers pick a region and a package; the control
plane places the VPS on a node with room. Customers never see, choose or run a
node.

The design is inspired by Fly.io: a fault-tolerant Elixir/Phoenix control plane
copes with many concurrent, flaky agent connections and multiplexes realtime VM
consoles, while a small, dependency-free Go agent runs on every worker node and
dials *out* to the control plane, so a node needs no inbound port-forward.

## What's in here

| Path             | What it is                                                                 |
| ---------------- | -------------------------------------------------------------------------- |
| `control_plane/` | Elixir **Phoenix 1.7** app (OTP app `:control_plane`), Postgres + Ecto.     |
| `agent/`         | Go **1.23** module `github.com/Bunk-Hosting/bunk-fleet/agent` (static build).|
| `docs/`          | Protocol contract (wire messages), architecture & roadmap.                 |

## Architecture

```
                          ┌───────────────────────────────────────────┐
                          │             CONTROL PLANE                  │
                          │        (Elixir / Phoenix 1.7, OTP)         │
                          │                                            │
  customers / API ─────▶  │  scheduler   enrollment   console mux      │
                          │  Ecto ─▶ Postgres                          │
                          └───────────────┬────────────────────────────┘
                                          │  HTTPS: enroll, heartbeat,
                                          │  command long-poll, result.
                                          │  Bearer agent token per node.
                                          │  AGENTS DIAL OUT (no inbound port)
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
        ┌─────┴──────┐              ┌──────┴─────┐              ┌──────┴─────┐
        │  bunk-agent│              │ bunk-agent │              │ bunk-agent │
        │   (Go)     │              │   (Go)     │              │   (Go)     │
        │  node 1    │              │  node 2    │              │  node 3    │
        └─────┬──────┘              └──────┬─────┘              └──────┬─────┘
              │ local API                  │ local API                 │ local API
        ┌─────┴──────┐              ┌──────┴─────┐              ┌──────┴─────┐
        │  Proxmox   │              │  Proxmox   │              │   ESXi     │
        │   (VMs)    │              │   (VMs)    │              │   (VMs)    │
        └────────────┘              └────────────┘              └────────────┘

        VPS instances are joined to a WireGuard overlay so that public
        endpoints and inter-VPS traffic are reachable regardless of each
        node's local network.
```

### Components

- **Control plane** — authoritative source of truth. Handles enrollment, holds
  node inventory + capacity, runs the scheduler, terminates customer/API
  requests, and multiplexes VM consoles back to users. Built on Elixir/OTP for
  fault tolerance and massive connection concurrency.
- **Agent (`bunk-agent`)** — one per worker node. Enrolls with a one-time
  token, heartbeats capacity on a timer, long-polls for work, executes
  provision/delete/console commands against the local hypervisor, and proxies
  consoles. Stdlib-only Go, ships as a single static binary.
- **Providers** — hypervisor backends behind the agent: **Proxmox** and
  **ESXi/vCenter**. The agent abstracts these so the control plane speaks one
  command vocabulary.
- **Overlay** — **WireGuard** connects VPS instances into one routable network
  for public endpoints and east-west traffic.
- **Scheduler** — the customer picks a **region**; the control plane places the
  VPS on the node *in that region* that keeps the most headroom afterwards,
  locking candidate rows so concurrent placements can't oversell a node.

## Quickstart

### Control plane (Elixir)

```bash
cd control_plane
mix deps.get && mix test
```

### Agent (Go)

```bash
cd agent
go build ./... && go test ./...
```

### Both at once

```bash
make test    # runs mix test (control_plane) + go test ./... (agent)
make build   # builds both
make fmt     # formats both
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — problem layers, stack,
  scheduling, overlay, failure modes, and phased roadmap.
- [`docs/protocol.md`](docs/protocol.md) — the agent ⇄ control-plane protocol
  contract (Enroll, Heartbeat, Command, CommandResult), transport, and security.
