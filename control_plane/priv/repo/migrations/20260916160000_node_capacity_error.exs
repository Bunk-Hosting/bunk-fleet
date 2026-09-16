defmodule ControlPlane.Repo.Migrations.NodeCapacityError do
  use Ecto.Migration

  # Een node waarvan de agent leeft maar de hypervisor-API niet kan bereiken zag
  # er tot nu toe hetzelfde uit als een machine die uit staat: geen heartbeat,
  # dus offline. Dat kost precies de informatie die nodig is om het op te lossen.
  #
  # De agent stuurt nu wel een heartbeat en zet hierin waarom hij geen capaciteit
  # kon opvragen. NULL betekent hier gewoon "geen probleem" -- dat geldt ook voor
  # alle bestaande rijen, dus er valt niets te backfillen.
  def change do
    alter table(:nodes) do
      add :capacity_error, :string
    end
  end
end
