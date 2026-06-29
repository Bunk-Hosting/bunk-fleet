defmodule ControlPlane.Fleet.Node do
  @moduledoc """
  A physical/virtual host enrolled in the fleet that can run VPSes. Nodes report
  their available capacity via heartbeats and are scheduled against by the
  `ControlPlane.Fleet.Scheduler`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Region
  alias ControlPlane.Net

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "nodes" do
    field :name, :string

    field :tier, Ecto.Enum, values: [:datacenter, :community], default: :community
    field :status, Ecto.Enum, values: [:pending, :online, :draining, :offline], default: :pending
    field :hypervisor, Ecto.Enum, values: [:proxmox, :esxi, :incus], default: :proxmox

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

    # Per-node VPS network (optional; nil = use the global default range). Bridge
    # and VLAN stay agent-local; the control plane only needs the IP range to hand
    # out non-conflicting addresses on this worker's subnet.
    field :vps_gateway, :string
    field :vps_cidr_prefix, :integer
    field :vps_range_start, :string
    field :vps_range_end, :string

    # WireGuard overlay: the node's wg public key + its assigned overlay /32.
    field :wg_public_key, :string
    field :overlay_ip, :string

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
      :owner_email,
      :vps_gateway,
      :vps_cidr_prefix,
      :vps_range_start,
      :vps_range_end,
      :wg_public_key,
      :overlay_ip
    ])
    |> validate_required([:name, :region_id])
    |> validate_vps_network()
    |> assoc_constraint(:region)
    |> unique_constraint(:agent_token_hash)
  end

  # If a worker declares ANY VPS-network field, require a complete, valid tuple so
  # the allocator can never crash on bad input or hand out a wrong-subnet address.
  @doc """
  Returns a changeset that adds a reservation's (or request's) vcpu/ram/disk back
  onto the node's available capacity — the one home for capacity-release math.
  """
  def add_capacity_changeset(%__MODULE__{} = node, %{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    change(node,
      available_vcpu: node.available_vcpu + vcpu,
      available_ram_mb: node.available_ram_mb + ram_mb,
      available_disk_gb: node.available_disk_gb + disk_gb
    )
  end

  @doc "Returns a changeset that subtracts vcpu/ram/disk from the node's available capacity."
  def subtract_capacity_changeset(%__MODULE__{} = node, %{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    change(node,
      available_vcpu: node.available_vcpu - vcpu,
      available_ram_mb: node.available_ram_mb - ram_mb,
      available_disk_gb: node.available_disk_gb - disk_gb
    )
  end

  defp validate_vps_network(changeset) do
    declared? =
      Enum.any?([:vps_range_start, :vps_range_end, :vps_gateway, :vps_cidr_prefix], fn f ->
        not is_nil(get_field(changeset, f))
      end)

    if declared? do
      changeset
      |> validate_required([:vps_range_start, :vps_range_end, :vps_gateway, :vps_cidr_prefix])
      |> validate_ipv4(:vps_range_start)
      |> validate_ipv4(:vps_range_end)
      |> validate_ipv4(:vps_gateway)
      |> validate_number(:vps_cidr_prefix, greater_than_or_equal_to: 1, less_than_or_equal_to: 32)
      |> validate_range_order()
    else
      changeset
    end
  end

  defp validate_ipv4(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Net.valid?(value), do: [], else: [{field, "is not a valid IPv4 address"}]
    end)
  end

  defp validate_range_order(changeset) do
    s = get_field(changeset, :vps_range_start)
    e = get_field(changeset, :vps_range_end)

    if is_binary(s) and is_binary(e) and Net.valid?(s) and Net.valid?(e) and
         Net.to_int(s) > Net.to_int(e) do
      add_error(changeset, :vps_range_end, "must be >= vps_range_start")
    else
      changeset
    end
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
