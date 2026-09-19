defmodule ControlPlane.Repo.Migrations.TellerOvergeslagenWachtwoordcontrole do
  use Ecto.Migration

  # De controle op gelekte wachtwoorden faalt bewust open: ligt de dienst plat,
  # dan gaat de registratie door. Dat is de juiste keuze -- niemand buitensluiten
  # omdat een derde partij eruit ligt -- maar hij heeft een prijs: "de controle
  # staat al maanden uit" en "de controle werkt" zien er vanaf hier precies
  # hetzelfde uit.
  #
  # Een dagteller maakt dat verschil zichtbaar zonder iets over een persoon vast
  # te leggen; deze tabel houdt alleen totalen per dag bij.
  def change do
    alter table(:auth_daily_stats) do
      add :hibp_skipped, :integer, null: false, default: 0
    end
  end
end
