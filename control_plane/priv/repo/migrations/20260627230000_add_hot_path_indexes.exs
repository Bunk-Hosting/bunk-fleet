defmodule ControlPlane.Repo.Migrations.AddHotPathIndexes do
  use Ecto.Migration

  def change do
    # active-VPS meter scan / quota / dashboard counts
    create_if_not_exists index(:vpses, [:status])
    # orphaned-reservation reclaim runs every 30s over status=:held
    create_if_not_exists index(:reservations, [:status], where: "status = 'held'", name: :reservations_held_idx)
    # payout_summary range scan over metered_at with no owner filter
    create_if_not_exists index(:usage_records, [:metered_at])
  end
end
