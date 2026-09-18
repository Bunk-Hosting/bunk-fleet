defmodule ControlPlane.Billing.UsageRecord do
  @moduledoc """
  A single accrued slice of resource usage for a VPS, recorded by a meter tick
  (see `ControlPlane.Billing.meter_active_vpses/1`).

  Each row says: for `seconds` seconds ending at `metered_at`, the given VPS of
  size `vcpu`/`ram_mb`/`disk_gb` ran on `node`, whose operator is `owner_email`.
  `owner_email` is denormalized off the node at meter time so cost reports
  can be aggregated (and grouped) directly from `usage_records`, and so the
  history stays correct even if the node or VPS is later removed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps

  @type t :: %__MODULE__{}

  # De sleutelkolom staat er nog. Hij wordt nergens opgezocht en verdwijnt in een
  # tweede stap; zolang de kolom in de database staat moet dit schema hem vullen,
  # want hij heeft geen default aan de databasekant.
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "usage_records" do
    field :owner_email, :string

    field :seconds, :integer
    field :vcpu, :integer
    field :ram_mb, :integer
    field :disk_gb, :integer

    field :metered_at, :utc_datetime

    belongs_to :vps, Vps
    belongs_to :node, Node

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(usage_record, attrs) do
    usage_record
    |> cast(attrs, [
      :vps_id,
      :node_id,
      :owner_email,
      :seconds,
      :vcpu,
      :ram_mb,
      :disk_gb,
      :metered_at
    ])
    |> validate_required([:owner_email, :seconds, :vcpu, :ram_mb, :disk_gb, :metered_at])
    |> validate_number(:seconds, greater_than_or_equal_to: 0)
    |> assoc_constraint(:vps)
    |> assoc_constraint(:node)
    # Backstop against double-billing the same VPS for the same time slice: each
    # meter tick stamps a fixed `metered_at`, so a duplicate insert for the same
    # (vps, tick) collides on this key.
    #
    |> unique_constraint([:vps_id, :metered_at],
      name: :usage_records_vps_id_metered_at_index
    )
  end
end
