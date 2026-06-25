defmodule ControlPlane.Repo.Migrations.AddLastMeteredAtToVpses do
  use Ecto.Migration

  def change do
    alter table(:vpses) do
      # Watermark for accrual metering: the timestamp through which this VPS has
      # already been billed. The next meter tick accrues usage for the interval
      # (last_metered_at .. now]. Null until the VPS is first metered, in which
      # case the meter falls back to `inserted_at`.
      add :last_metered_at, :utc_datetime
    end
  end
end
