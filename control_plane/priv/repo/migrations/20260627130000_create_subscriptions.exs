defmodule ControlPlane.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :delete_all), null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :package_id, references(:packages, on_delete: :nilify_all)
      add :price_monthly, :decimal, precision: 8, scale: 2, null: false
      add :status, :string, null: false, default: "active"
      add :billing_cycle, :string, null: false, default: "monthly"
      add :started_at, :utc_datetime
      add :next_billing_date, :date
      add :cancelled_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:vps_id])
    create index(:subscriptions, [:owner_id])
    create index(:subscriptions, [:status])
  end
end
