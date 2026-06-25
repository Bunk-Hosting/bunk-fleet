defmodule ControlPlane.Fleet.Node do
  @moduledoc """
  A physical/virtual host enrolled in the fleet that can run VPSes. Nodes report
  their available capacity via heartbeats and are scheduled against by the
  `ControlPlane.Fleet.Scheduler`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Region

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "nodes" do
    field :name, :string

    field :tier, Ecto.Enum, values: [:datacenter, :community], default: :community
    field :status, Ecto.Enum, values: [:pending, :online, :draining, :offline], default: :pending
    field :hypervisor, Ecto.Enum, values: [:proxmox, :incus], default: :proxmox

    # Total advertised capacity of the node.
    field :total_vcpu, :integer
    field :total_ram_mb, :integer
    field :total_disk_gb, :integer

    # Live, currently-available capacity (decremented by the scheduler on placement
    # and refreshed by heartbeats).
    field :available_vcpu, :integer
    field :available_ram_mb, :integer
    field :available_disk_gb, :integer

    field :last_heartbeat_at, :utc_datetime
    field :enroll_token_hash, :string
    field :agent_token_hash, :string
    field :public_key, :string
    field :owner_email, :string

    belongs_to :region, Region

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :name,
      :region_id,
      :tier,
      :status,
      :hypervisor,
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :available_vcpu,
      :available_ram_mb,
      :available_disk_gb,
      :last_heartbeat_at,
      :enroll_token_hash,
      :agent_token_hash,
      :public_key,
      :owner_email
    ])
    |> validate_required([:name, :region_id])
    |> assoc_constraint(:region)
    |> unique_constraint(:agent_token_hash)
  end

  @doc """
  Changeset applied when a node reports a heartbeat.

  A heartbeat updates only the node's advertised *total* capacity (the operator
  may add/remove hardware) and the heartbeat timestamp. It deliberately does NOT
  touch `available_*` — that is managed exclusively by the
  `ControlPlane.Fleet.Scheduler` (decremented on placement, released on delete),
  so an untrusted heartbeat can never undo a reservation and overcommit a node.
  It also does NOT set `:status`: node status is transitioned by authorized
  server-side logic, never driven by the least-trusted (agent) input.
  """
  def heartbeat_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :last_heartbeat_at
    ])
    |> validate_required([:last_heartbeat_at])
  end

  @doc """
  Server-side changeset applied when an authenticated heartbeat both refreshes a
  node's advertised totals AND (re)asserts it as `:online`.

  Unlike `heartbeat_changeset/2`, this one is allowed to set `:status` because it is
  driven by trusted server logic (`ControlPlane.Fleet.mark_online_heartbeat/2`)
  after the agent's bearer token has been authenticated — not directly from agent
  input. `available_*` may be set ONLY here and ONLY to seed a brand-new node's
  capacity on its first heartbeat (see `Fleet.mark_online_heartbeat/2`); steady-state
  it stays scheduler-owned.
  """
  def mark_online_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :available_vcpu,
      :available_ram_mb,
      :available_disk_gb,
      :last_heartbeat_at,
      :status
    ])
    |> validate_required([:last_heartbeat_at, :status])
  end
end
