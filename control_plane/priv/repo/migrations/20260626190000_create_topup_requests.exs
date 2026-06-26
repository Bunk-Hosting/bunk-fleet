defmodule ControlPlane.Repo.Migrations.CreateTopupRequests do
  use Ecto.Migration

  def change do
    create table(:topup_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :reference, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :paid_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:topup_requests, [:reference])
    create index(:topup_requests, [:user_id])
    create index(:topup_requests, [:status])
  end
end
