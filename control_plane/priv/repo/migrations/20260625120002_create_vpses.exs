defmodule ControlPlane.Repo.Migrations.CreateVpses do
  use Ecto.Migration

  def change do
    create table(:vpses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      add :status, :string, null: false, default: "queued"

      add :vcpu, :integer, null: false
      add :ram_mb, :integer, null: false
      add :disk_gb, :integer, null: false

      add :owner_email, :string

      add :region_id, references(:regions, type: :binary_id, on_delete: :restrict), null: false
      add :node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:vpses, [:region_id])
    create index(:vpses, [:node_id])
  end
end
