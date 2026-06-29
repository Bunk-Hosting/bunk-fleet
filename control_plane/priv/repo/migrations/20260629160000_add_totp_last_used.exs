defmodule ControlPlane.Repo.Migrations.AddTotpLastUsed do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_last_used_at, :utc_datetime
    end
  end
end
