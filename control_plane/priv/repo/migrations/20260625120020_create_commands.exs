defmodule ControlPlane.Repo.Migrations.CreateCommands do
  use Ecto.Migration

  def change do
    create table(:commands, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :result, :map

      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:commands, [:node_id, :status])
    create index(:commands, [:vps_id])
  end
end
