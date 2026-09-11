defmodule ControlPlane.Repo.Migrations.PortForwards do
  @moduledoc """
  Gives a VPS an address a customer can actually connect to.

  Until now the dashboard handed people `10.10.0.21:22` — an address that is not
  routable from anywhere except the one machine the VPS runs on. The product
  could not deliver what a VPS is.

  A node's customers share the node's public address and are told apart by port,
  which is the shape the Starter tier was priced for: a dedicated IPv4 costs
  €2.27/month against a €3.99 plan, and there are none to hand out anyway.
  """
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      # Where customers reach this node from the internet. Null means "nowhere
      # yet" — which is the honest state of a node behind a home connection, and
      # the reason the UI has to be able to say so rather than print a private
      # address and hope.
      add :public_host, :string
      # The port range the operator has forwarded to this node. Defaults chosen to
      # sit well above anything a hypervisor or its management tools use.
      add :public_port_start, :integer, default: 20_000, null: false
      add :public_port_end, :integer, default: 29_999, null: false
    end

    create table(:port_forwards, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :delete_all), null: false
      # Denormalised from the VPS on purpose: uniqueness is per node (two nodes
      # may each use port 20001), and the agent syncs by node without joining.
      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false

      add :public_port, :integer, null: false
      add :target_port, :integer, null: false
      add :protocol, :string, null: false, default: "tcp"
      # What it is for, so a customer's port list reads as something other than
      # numbers: "ssh", "http", "game".
      add :purpose, :string

      timestamps(type: :utc_datetime)
    end

    # The backstop behind the allocator's advisory lock: two concurrent creates on
    # one node can never be handed the same port.
    create unique_index(:port_forwards, [:node_id, :protocol, :public_port])
    create index(:port_forwards, [:vps_id])
  end
end
