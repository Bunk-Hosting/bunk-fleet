defmodule ControlPlane.Repo.Migrations.NodeBridgeEnVlan do
  use Ecto.Migration

  # De bridge waar klant-VPSen aan hangen stond alleen in het env-bestand op de
  # machine zelf (BUNK_VPS_BRIDGE). Daarmee was hij niet te zien in het
  # dashboard en niet te wijzigen zonder een terminal op die node -- terwijl de
  # rest van de node-instellingen daar wel staat.
  #
  # NULL betekent "niet ingesteld": de agent houdt dan wat in zijn eigen config
  # staat. Dat is bewust geen lege string, want leeg is bij een bridge ook een
  # betekenis ("neem over van de template").
  def change do
    alter table(:nodes) do
      add :vps_bridge, :string
      add :vps_vlan, :integer
    end
  end
end
