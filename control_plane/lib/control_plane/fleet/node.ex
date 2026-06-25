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
      :public_key,
      :owner_email
    ])
    |> validate_required([:name, :region_id])
    |> assoc_constraint(:region)
  end

  @doc """
  Changeset applied when a node reports a heartbeat: refreshes the live available
  capacity, the heartbeat timestamp, and (optionally) the status.
  """
  def heartbeat_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :available_vcpu,
      :available_ram_mb,
      :available_disk_gb,
      :last_heartbeat_at,
      :status
    ])
    |> validate_required([:last_heartbeat_at])
  end
end
