# Agent ⇄ Control-Plane Protocol

This document is the contract between the Go **bunk-agent** running on each
worker node and the Elixir **control plane**. It defines the transport, the
message set, and the security model.

> **Status: partly aspirational.** The message *set* below matches the
> implementation, but the transport and identity sections describe a design we
> have not built. What actually ships today: enrollment and steady state both
> run over plain **HTTPS request/response**, steady state is a **long-poll** for
> commands plus a periodic heartbeat (not a persistent bidirectional stream),
> and a node authenticates with a **per-node bearer token** minted at enrollment
> — there is no mTLS, no CSR, and no CA bundle. Sections marked *(designed)*
> are not in the code. Do not assume mTLS exists.

## Transport

- **Agents dial OUT.** Worker nodes may live behind NAT/firewalls and are
  never dialed *into*. The agent always initiates the connection to the control
  plane, which keeps the protocol NAT-friendly with no inbound ports.
- **Enrollment** happens once, over **HTTPS** (request/response), using a
  one-time enrollment token. It returns the node's durable identity.
- **Steady state** runs over a single **persistent, authenticated, bidirectional
  channel** — either **gRPC streaming** or a **WebSocket** — carrying heartbeats
  (agent→cp), commands (cp→agent), and command results (agent→cp) multiplexed
  together, plus console byte streams.
- **Reconnect** is mandatory and continuous: on disconnect the agent retries
  with exponential backoff + jitter and re-establishes the channel using its
  durable mTLS identity (no re-enrollment). The control plane treats a node as
  online only while its channel is live and heartbeats are fresh.

### Direction legend

- `agent→cp` : sent by the agent to the control plane.
- `cp→agent` : sent by the control plane to the agent.

---

## Messages

### `Enroll` — bootstrap a new node (HTTPS, one-time)

**Request — `agent→cp`**

| Field             | Type     | Notes                                              |
| ----------------- | -------- | -------------------------------------------------- |
| `enrollment_token`| string   | One-time token minted by an admin. Single-use.     |
| `hostname`        | string   | Agent-reported node hostname.                      |
| `hypervisor`      | enum     | `proxmox` \| `esxi`.                               |
| `agent_version`   | string   | bunk-agent build version.                          |
| `advertised_region`| string  | Region the agent claims for this node.             |
| `csr`             | bytes    | *(designed)* PEM CSR; key never leaves the node.   |

**Response — `cp→agent`**

| Field             | Type     | Notes                                              |
| ----------------- | -------- | -------------------------------------------------- |
| `node_id`         | uuid     | Durable control-plane identity for this node.      |
| `client_cert`     | bytes    | *(designed)* Signed mTLS client cert. Today: a per-node bearer `agent_token`. |
| `ca_bundle`       | bytes    | *(designed)* CA chain for verifying the control plane.|
| `assigned_region` | string   | Authoritative region assignment.                   |
| `channel_endpoint`| string   | URL/host:port for the persistent channel.          |

After a successful `Enroll`, the one-time token is burned and the node uses its
per-node agent token (bearer) for all subsequent calls. Only the token's hash is
stored control-plane side.

---

### `Heartbeat` — capacity & liveness (channel, every N seconds)

**`agent→cp`** — emitted on a fixed interval (default every N seconds).

| Field                 | Type   | Notes                                          |
| --------------------- | ------ | ---------------------------------------------- |
| `node_id`             | uuid   | Identity of the reporting node.                |
| `seq`                 | uint64 | Monotonic sequence number.                     |
| `hypervisor`          | enum   | `proxmox` \| `esxi`.                          |
| `capacity_total`      | object | `{ vcpu, ram_mb, disk_gb }` — physical totals. |
| `capacity_available`  | object | `{ vcpu, ram_mb, disk_gb }` — schedulable now. |
| `capacity_error`      | string | Why this heartbeat carries no measured capacity. Absent when all is well. |
| `health`              | enum   | `healthy` \| `degraded` \| `draining`.         |
| `running_vms`         | uint   | Count of active VMs (sanity/reconciliation).   |

Missed heartbeats (channel down or stale `seq`) mark the node offline and
trigger drain/reschedule (see `architecture.md`). Capacity from the latest
heartbeat is the scheduler's input for placement.

**`capacity_error` exists because silence is ambiguous.** An agent that cannot
reach its hypervisor used to send nothing at all, so the node went offline after
the heartbeat TTL — indistinguishable from a machine that is switched off, and
missing the one fact needed to fix it. Such an agent now heartbeats anyway and
says why it has no numbers. The control plane keeps the last known totals (the
zeroes in that message are the absence of a measurement, not a measurement of
zero), sets what the node reports as free to zero so nothing is placed there, and
clears the field on the next healthy heartbeat.

**Available vCPU is oversubscribed, available RAM is not.** Hand out more RAM
than exists and something gets killed; a vCPU is a share of time. The agent
reports `cores × BUNK_VCPU_OVERSUBSCRIBE − assigned` (default factor 3) as
available, while `capacity_total.vcpu` stays the honest physical count.

---

### `Command` — control-plane → agent instruction (channel)

**`cp→agent`** — each command carries a `command_id` (uuid) the agent echoes in
its `CommandResult`, plus a `vps_id` (uuid, or absent for a command about the
node itself such as `inventory` and `update`). The agent uses `vps_id` only to
decide what may run next to what: commands for different VPSes run in parallel,
commands for one VPS strictly in the order they were delivered. An agent that
does not see the field falls back to running everything one at a time, which is
correct but slow, so an old agent against a new control plane keeps working.
How many VPSes one agent works on at once is `BUNK_MAX_PARALLEL_COMMANDS`
(default 4; set it to 1 on slow storage to get the strictly-sequential behaviour
back). One of the following payloads:

#### `provision`

| Field         | Type   | Notes                                               |
| ------------- | ------ | --------------------------------------------------- |
| `name`        | string | Guest name on the hypervisor.                        |
| `vcpu` / `ram_mb` / `disk_gb` | int | The requested spec.                     |
| `template_id` | int    | Template to clone.                                   |
| `cloud_init`  | object | cloud-init data rendered by the control plane.       |
| `ssh_keys`    | []string| Authorized public keys, plus the console key.       |
| `ip_config`   | string | Provider-native addressing: `ip=A.B.C.D/prefix,gw=…`, allocated from the node's own subnet. |

#### `delete`

| Field    | Type   | Notes                                |
| -------- | ------ | ------------------------------------ |
| `vm_id`  | string | Hypervisor-local VM identifier.      |

#### `console_connect`

Not a command in the usual sense: it changes nothing, reports no result, and is
never redelivered. It rides the command poll because that is the channel the
agent already holds open.

| Field      | Type   | Notes                                                  |
| ---------- | ------ | ------------------------------------------------------ |
| `token`    | string | Single-use relay token. The agent presents it on `GET /v1/console-relay`, which upgrades to a WebSocket carrying raw SSH bytes. |
| `vps_id`   | uuid   | The VPS this console is for.                           |
| `host`     | string | Address to open TCP to, on the node's own network. The agent refuses anything that is not private, and outside its assigned subnet where it knows one. |
| `port`     | int    | Usually 22.                                            |

---

### `CommandResult` — agent → control-plane outcome (channel)

**`agent→cp`** — one per executed `Command`, correlated by `command_id`.

| Field         | Type   | Notes                                                  |
| ------------- | ------ | ------------------------------------------------------ |
| `status`      | enum   | `done` \| `failed`.                                    |
| `vm_id`       | string | Hypervisor-local VM id (on provision).                 |
| `ip`          | string | The guest's primary IPv4, when known. The control plane keeps its own allocation when the two disagree — the console binds to the address it assigned. |
| `error`       | string | Human-readable failure reason when `status = failed`.  |

---

## Security

- **mTLS identity per node.** Each node holds a unique client certificate issued
  at enrollment; the agent's private key never leaves the node. The control
  plane authenticates every HTTPS call by bearer token today, binding it to a
  `node_id`; certificate identity is *(designed)*, not built.
- **One-time enrollment tokens.** Tokens are single-use and short-lived; they
  bootstrap identity only and grant no standing access.
- **Least privilege.** A node may only act on VMs/VPS instances the control
  plane has assigned to it. Commands are scoped to that node; an agent cannot
  enumerate or affect other nodes' workloads.
- **Control-plane authentication.** The agent verifies the control plane against
  the `ca_bundle` from enrollment, preventing impersonation of the orchestrator.
- **No node trust tiers.** Every node is Bunk's own hardware, so there is no
  untrusted class of node to fence off. The boundary that matters is between
  *tenants*, and it is enforced in the control plane (owner-scoped queries,
  server-set VPS ownership, CP-allocated console IPs), not by node class.
