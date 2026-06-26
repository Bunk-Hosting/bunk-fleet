defmodule ControlPlane.Repo.Migrations.UniqueActiveVpsIp do
  use Ecto.Migration

  def change do
    # A live VPS's IP must be unique; freed (:deleted) addresses may be reused.
    create unique_index(:vpses, [:ip_address],
             where: "ip_address IS NOT NULL AND status != 'deleted'",
             name: :vpses_active_ip_uidx
           )
  end
end
