defmodule ControlPlane.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # `citext` gives us case-insensitive, but otherwise normal, text columns —
    # used for the email so "User@Example.com" and "user@example.com" collide on
    # the unique index below.
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :role, :string, null: false, default: "user"
      add :name, :string
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
  end
end
