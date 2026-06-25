defmodule ControlPlane.Fleet.Vps do
  @moduledoc """
  A virtual private server requested by a customer, placed onto a node within a
  region.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Accounts.User
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

    # The authenticated account that owns this VPS (nil for admin-/system-created
    # VPSes). `owner_email` is a free-text label kept for admin-created rows and
    # display; `owner_id` is the authoritative ownership link for authorization.
    field :owner_email, :string
    belongs_to :user, User, foreign_key: :owner_id

    # Provider-side identity, populated once the node's agent reports a successful
    # provision result.
    field :provider_vm_id, :string
    field :ip_address, :string

    # Accrual-metering watermark: the timestamp through which this VPS has
    # already been metered into `usage_records` (see `ControlPlane.Billing`).
    field :last_metered_at, :utc_datetime

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
      :owner_id,
      :provider_vm_id,
      :ip_address,
      :last_metered_at
    ])
    |> validate_required([:name, :region_id, :vcpu, :ram_mb, :disk_gb])
    |> assoc_constraint(:region)
    |> assoc_constraint(:node)
    |> assoc_constraint(:user)
  end
end
