defmodule ControlPlane.Repo.Migrations.BandwidthTbWeg do
  use Ecto.Migration

  # De contract-stap. De vorige uitrol haalde bandwidth_tb uit het schema, uit
  # beide API-antwoorden en uit de frontend; sindsdien leest niets de kolom nog.
  # Pas nu mag hij weg.
  #
  # Andersom zou het misgaan: migraties draaien vóór de containerwissel, dus
  # tussen het droppen en de nieuwe code in selecteert de oude code een minuut
  # lang een kolom die er niet meer is -- en dan valt elke pakketvraag om.
  #
  # `down` geeft de kolom terug met de waarde die er altijd stond. De gegevens
  # zijn niet te herstellen, maar er viel ook niets te herstellen: er is nooit
  # een byte tegen afgemeten.
  def up do
    alter table(:packages) do
      remove :bandwidth_tb
    end
  end

  def down do
    alter table(:packages) do
      add :bandwidth_tb, :integer, default: 1
    end
  end
end
