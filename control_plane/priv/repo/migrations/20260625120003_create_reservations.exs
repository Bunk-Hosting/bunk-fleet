defmodule ControlPlane.Repo.Migrations.CreateReservations do
  use Ecto.Migration

  def change do
    create table(:reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :vcpu, :integer, null: false
      add :ram_mb, :integer, null: false
      add :disk_gb, :integer, null: false

      add :status, :string, null: false, default: "held"

      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:reservations, [:node_id])
    create index(:reservations, [:vps_id])
  end
end
