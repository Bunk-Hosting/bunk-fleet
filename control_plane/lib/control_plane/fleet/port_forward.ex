defmodule ControlPlane.Fleet.PortForward do
  @moduledoc """
  One `public_host:public_port` → `vps_ip:target_port` mapping on a node.

  Customers on a node share its public address and are told apart by port. That
  is not a compromise forced by laziness: a dedicated IPv4 costs about €2.27 a
  month against a €3.99 plan, and the fleet has none to hand out. Ports are free.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "port_forwards" do
    belongs_to :vps, Vps
    belongs_to :node, Node

    field :public_port, :integer
    field :target_port, :integer
    field :protocol, Ecto.Enum, values: [:tcp, :udp], default: :tcp
    field :purpose, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(forward, attrs) do
    forward
    |> cast(attrs, [:vps_id, :node_id, :public_port, :target_port, :protocol, :purpose])
    |> validate_required([:vps_id, :node_id, :public_port, :target_port])
    |> validate_number(:public_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:target_port, greater_than: 0, less_than: 65_536)
    |> validate_length(:purpose, max: 40)
    # The purpose is rendered to the customer and shipped to the agent, which
    # puts it near a shell. Keep it to something that cannot be anything else.
    |> validate_format(:purpose, ~r/\A[a-z0-9-]*\z/,
      message: "mag alleen kleine letters, cijfers en koppeltekens bevatten"
    )
    |> assoc_constraint(:vps)
    |> assoc_constraint(:node)
    |> unique_constraint([:node_id, :protocol, :public_port],
      name: :port_forwards_node_id_protocol_public_port_index
    )
  end
end
