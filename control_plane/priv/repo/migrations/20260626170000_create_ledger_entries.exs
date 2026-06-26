defmodule ControlPlane.Repo.Migrations.CreateLedgerEntries do
  use Ecto.Migration

  def change do
    create table(:ledger_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :kind, :string, null: false
      add :description, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:ledger_entries, [:user_id])
  end
end
