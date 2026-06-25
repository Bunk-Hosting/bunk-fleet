defmodule ControlPlane.Fleet.Vps do
  @moduledoc """
  A virtual private server requested by a customer, placed onto a node within a
  region.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.{Node, Region}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vpses" do
    field :name, :string

    field :status, Ecto.Enum,
      values: [:queued, :provisioning, :active, :failed, :deleting, :deleted],
      default: :queued

    # Requested spec.
    field :vcpu, :integer
    field :ram_mb, :integer
    field :disk_gb, :integer

    field :owner_email, :string

    # Provider-side identity, populated once the node's agent reports a successful
    # provision result.
    field :provider_vm_id, :string
    field :ip_address, :string

    belongs_to :region, Region
    belongs_to :node, Node

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(vps, attrs) do
    vps
    |> cast(attrs, [
      :name,
      :region_id,
      :node_id,
      :status,
      :vcpu,
      :ram_mb,
      :disk_gb,
      :owner_email,
      :provider_vm_id,
      :ip_address
    ])
    |> validate_required([:name, :region_id, :vcpu, :ram_mb, :disk_gb])
    |> assoc_constraint(:region)
    |> assoc_constraint(:node)
  end
end
