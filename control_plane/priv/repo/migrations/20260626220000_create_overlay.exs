defmodule ControlPlane.Repo.Migrations.CreateOverlay do
  use Ecto.Migration

  def change do
    create table(:overlay_config, primary_key: false) do
      add :id, :integer, primary_key: true
      add :hub_private_key, :string, null: false
      add :hub_public_key, :string, null: false
      timestamps(type: :utc_datetime)
    end

    alter table(:nodes) do
      add :wg_public_key, :string
      add :overlay_ip, :string
    end

    create unique_index(:nodes, [:overlay_ip],
             where: "overlay_ip IS NOT NULL",
             name: :nodes_overlay_ip_uidx
           )
  end
end
