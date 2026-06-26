defmodule ControlPlane.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret, :binary
      add :totp_confirmed_at, :utc_datetime
    end
  end
end
