defmodule ControlPlane.Repo.Migrations.AddVpsNetworkToNodes do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :vps_gateway, :string
      add :vps_cidr_prefix, :integer
      add :vps_range_start, :string
      add :vps_range_end, :string
    end
  end
end
