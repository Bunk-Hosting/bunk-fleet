defmodule ControlPlane.Repo.Migrations.AddAgentTokenHashToNodes do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :agent_token_hash, :string
    end

    create unique_index(:nodes, [:agent_token_hash])
  end
end
