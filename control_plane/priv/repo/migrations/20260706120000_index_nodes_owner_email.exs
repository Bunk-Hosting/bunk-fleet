defmodule ControlPlane.Repo.Migrations.IndexNodesOwnerEmail do
  use Ecto.Migration

  def change do
    # The operator dashboard lists a node owner's machines via
    # Fleet.list_nodes_for_owner/1, which filters on owner_email. Index it so that
    # hot path stays cheap as the nodes table grows.
    create index(:nodes, [:owner_email])
  end
end
