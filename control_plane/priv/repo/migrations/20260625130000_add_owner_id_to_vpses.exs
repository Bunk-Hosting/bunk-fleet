defmodule ControlPlane.Repo.Migrations.AddOwnerIdToVpses do
  use Ecto.Migration

  # Links a VPS to the authenticated `users` record that owns it. Nullable so
  # admin-/system-created VPSes (and historical rows) without a user owner remain
  # valid; `on_delete: :nilify_all` keeps a deleted account's VPS rows intact
  # (orphaned, but auditable) rather than cascading them away.
  def change do
    alter table(:vpses) do
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:vpses, [:owner_id])
  end
end
