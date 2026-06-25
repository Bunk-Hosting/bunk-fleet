# Agent ⇄ Control-Plane Protocol

This document is the contract between the Go **bunk-agent** running on each
worker node and the Elixir **control plane**. It defines the transport, the
message set, and the security model.

## Transport

- **Agents dial OUT.** Worker nodes live behind operator NAT/firewalls and are
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
| `enrollment_token`| string   | One-time token issued to the operator. Single-use. |
| `hostname`        | string   | Operator-reported node hostname.                   |
| `hypervisor`      | enum     | `proxmox` \| `incus`.                              |
| `agent_version`   | string   | bunk-agent build version.                          |
| `advertised_region`| string  | Region the operator claims for this node.          |
| `csr`             | bytes    | PEM CSR; the node's private key never leaves it.   |

**Response — `cp→agent`**

| Field             | Type     | Notes                                              |
| ----------------- | -------- | -------------------------------------------------- |
| `node_id`         | uuid     | Durable control-plane identity for this node.      |
| `client_cert`     | bytes    | Signed mTLS client certificate (node identity).    |
| `ca_bundle`       | bytes    | CA chain the agent uses to verify the control plane.|
| `assigned_region` | string   | Authoritative region assignment.                   |
| `channel_endpoint`| string   | URL/host:port for the persistent channel.          |
| `trust_tier`      | enum     | `datacenter` \| `community`.                        |

After a successful `Enroll`, the one-time token is burned and the node uses its
mTLS identity for all subsequent connections.

---

### `Heartbeat` — capacity & liveness (channel, every N seconds)

**`agent→cp`** — emitted on a fixed interval (default every N seconds).

| Field                 | Type   | Notes                                          |
| --------------------- | ------ | ---------------------------------------------- |
| `node_id`             | uuid   | Identity of the reporting node.                |
| `seq`                 | uint64 | Monotonic sequence number.                     |
| `hypervisor`          | enum   | `proxmox` \| `incus`.                          |
| `capacity_total`      | object | `{ vcpu, ram_mb, disk_gb }` — physical totals. |
| `capacity_available`  | object | `{ vcpu, ram_mb, disk_gb }` — schedulable now. |
| `health`              | enum   | `healthy` \| `degraded` \| `draining`.         |
| `running_vms`         | uint   | Count of active VMs (sanity/reconciliation).   |

Missed heartbeats (channel down or stale `seq`) mark the node offline and
trigger drain/reschedule (see `architecture.md`). Capacity from the latest
heartbeat is the scheduler's input for placement.

---

### `Command` — control-plane → agent instruction (channel)

**`cp→agent`** — each command carries a `command_id` (uuid) the agent echoes in
its `CommandResult`. One of the following payloads:

#### `provision`

| Field         | Type   | Notes                                               |
| ------------- | ------ | --------------------------------------------------- |
| `vps_id`      | uuid   | Logical VPS this VM backs.                           |
| `spec`        | object | `{ vcpu, ram_mb, disk_gb, image }`.                 |
| `cloud_init`  | string | cloud-init user-data rendered by the control plane. |
| `ssh_keys`    | []string| Authorized public keys for the instance.           |
| `ip`          | object | `{ overlay_ip, public_ip? }` to assign on the VM.   |

#### `delete`

| Field    | Type   | Notes                                |
| -------- | ------ | ------------------------------------ |
| `vm_id`  | string | Hypervisor-local VM identifier.      |

#### `console-open`

| Field      | Type   | Notes                                         |
| ---------- | ------ | --------------------------------------------- |
| `vm_id`    | string | Target VM.                                    |
| `session`  | uuid   | Console session id; subsequent console bytes  |
|            |        | are multiplexed on the channel under this id. |

---

### `CommandResult` — agent → control-plane outcome (channel)

**`agent→cp`** — one per executed `Command`, correlated by `command_id`.

| Field         | Type   | Notes                                                  |
| ------------- | ------ | ------------------------------------------------------ |
| `command_id`  | uuid   | Echoes the originating `Command`.                      |
| `node_id`     | uuid   | Reporting node.                                        |
| `status`      | enum   | `ok` \| `error` \| `in_progress`.                      |
| `vm_id`       | string | Hypervisor-local VM id (on provision/delete).          |
| `ip`          | object | Assigned `{ overlay_ip, public_ip? }` (on provision).  |
| `error`       | string | Human-readable failure reason when `status = error`.   |

---

## Security

- **mTLS identity per node.** Each node holds a unique client certificate issued
  at enrollment; the agent's private key never leaves the node. The control
  plane authenticates every channel and HTTPS call by certificate, binding it to
  a `node_id` and `trust_tier`.
- **One-time enrollment tokens.** Tokens are single-use and short-lived; they
  bootstrap identity only and grant no standing access.
- **Least privilege.** A node may only act on VMs/VPS instances the control
  plane has assigned to it. Commands are scoped to that node; an agent cannot
  enumerate or affect other nodes' workloads.
- **Control-plane authentication.** The agent verifies the control plane against
  the `ca_bundle` from enrollment, preventing impersonation of the orchestrator.
- **Trust tiers** (`datacenter` vs `community`) feed scheduling and placement
  policy; lower-trust community nodes are additionally gated by reputation and
  operator deposit.
