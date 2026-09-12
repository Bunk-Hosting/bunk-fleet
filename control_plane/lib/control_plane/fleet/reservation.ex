defmodule ControlPlane.Fleet.Reservation do
  @moduledoc """
  A capacity reservation held against a node for a particular VPS. Created in the
  `:held` state by the scheduler when a VPS is placed; later `:committed` once the
  VPS is provisioned, or `:released` if placement is abandoned.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reservations" do
    field :vcpu, :integer
    field :ram_mb, :integer
    field :disk_gb, :integer

    field :status, Ecto.Enum, values: [:held, :committed, :released], default: :held

    belongs_to :node, Node
    belongs_to :vps, Vps

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [:node_id, :vps_id, :vcpu, :ram_mb, :disk_gb, :status])
    |> validate_required([:node_id, :vcpu, :ram_mb, :disk_gb])
    |> assoc_constraint(:node)
    |> assoc_constraint(:vps)
  end
end
