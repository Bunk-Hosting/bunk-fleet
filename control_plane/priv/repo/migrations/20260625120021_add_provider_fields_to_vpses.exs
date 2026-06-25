defmodule ControlPlane.Repo.Migrations.AddProviderFieldsToVpses do
  use Ecto.Migration

  def change do
    alter table(:vpses) do
      add :provider_vm_id, :string
      add :ip_address, :string
    end
  end
end
