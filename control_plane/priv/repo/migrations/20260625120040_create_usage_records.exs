defmodule ControlPlane.Repo.Migrations.CreateUsageRecords do
  use Ecto.Migration

  def change do
    create table(:usage_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The metered VPS and the node it ran on. We keep both VPS and node so a
      # record survives the VPS being deleted (node is :nilify_all-free here:
      # usage history must outlive both, so neither cascades a delete).
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)
      add :node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)

      # Node operator, denormalized off the node at meter time so payouts can be
      # grouped/aggregated without joining (and stay correct even if the node is
      # later removed).
      add :owner_email, :string, null: false

      # Seconds of usage this record accounts for, plus the VPS resource size at
      # meter time (vcpu count, RAM in MB, disk in GB).
      add :seconds, :integer, null: false
      add :vcpu, :integer, null: false
      add :ram_mb, :integer, null: false
      add :disk_gb, :integer, null: false

      # When this slice of usage was metered (end of the accrual window).
      add :metered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:usage_records, [:node_id, :metered_at])
    create index(:usage_records, [:owner_email, :metered_at])
  end
end
