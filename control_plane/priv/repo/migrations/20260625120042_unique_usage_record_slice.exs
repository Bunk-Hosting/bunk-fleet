defmodule ControlPlane.Repo.Migrations.UniqueUsageRecordSlice do
  use Ecto.Migration

  def change do
    # Hard data-layer backstop against double-billing a VPS for the same time
    # slice: each meter tick stamps every record with the same `metered_at`, so a
    # second (concurrent or retried) meter of the same VPS at the same tick would
    # collide here and fail instead of accruing duplicate usage. See
    # `ControlPlane.Billing.meter_active_vpses/1`, which also locks the VPS row
    # `FOR UPDATE` to serialize meterings.
    create unique_index(:usage_records, [:vps_id, :metered_at])
  end
end
