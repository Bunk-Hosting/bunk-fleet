defmodule ControlPlane.Repo.Migrations.NodeDrainReason do
  use Ecto.Migration

  # Een node kan afgesloten staan omdat een beheerder dat wilde, of omdat het
  # systeem hem heeft dichtgezet na een mislukte bestelling. In het paneel zag
  # dat er hetzelfde uit: "draining", zonder waarom. Wie er een week later naar
  # kijkt weet dan niet of hij hem weer open mag zetten.
  #
  # NULL betekent "met de hand afgesloten, of niet afgesloten" -- dat klopt ook
  # voor alle bestaande rijen, dus er valt niets te backfillen.
  def change do
    alter table(:nodes) do
      add :drain_reason, :string
    end
  end
end
