defmodule ControlPlane.Repo.Migrations.CreateEnrollTokens do
  use Ecto.Migration

  def change do
    create table(:enroll_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      add :tier, :string, null: false, default: "community"
      add :expires_at, :utc_datetime
      add :used_at, :utc_datetime

      add :region_id, references(:regions, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:enroll_tokens, [:token_hash])
    create index(:enroll_tokens, [:region_id])
  end
end
