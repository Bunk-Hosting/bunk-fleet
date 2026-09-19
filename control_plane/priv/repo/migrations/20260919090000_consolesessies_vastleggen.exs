defmodule ControlPlane.Repo.Migrations.ConsolesessiesVastleggen do
  use Ecto.Migration

  # Het control plane zet bij elke uitrol zijn eigen sleutel in de
  # authorized_keys van de klant. Dat is nodig voor de webterminal, en het
  # betekent dat Bunk root heeft op elke VPS. Die bevoegdheid is niet weg te
  # nemen zonder de webterminal weg te nemen -- maar wel te verantwoorden.
  #
  # Deze tabel is die verantwoording: wie, welke machine, wanneer begonnen,
  # wanneer geëindigd. Hij staat er niet voor ons maar voor de klant, en daarom
  # zit hij ook in de uitdraai van een inzageverzoek. Zonder dit is "wij kijken
  # niet in je VPS" een belofte zonder bewijs, en met dit is het een uitspraak
  # die iemand kan narekenen.
  #
  # ended_at blijft leeg als een sessie niet netjes is afgelopen (een herstart
  # van het control plane midden in een sessie). Dat is geen fout in de
  # administratie maar precies wat er gebeurde.
  def change do
    create table(:console_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)

      # Vastgelegd op het moment zelf en niet later afgeleid: is de VPS
      # verwijderd of de gebruiker geanonimiseerd, dan is niet meer na te gaan
      # of degene aan de terminal de eigenaar was of iemand van Bunk. Juist dat
      # is de vraag die deze tabel moet kunnen beantwoorden.
      add :door_beheerder, :boolean, null: false, default: false

      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :reden_einde, :string

      timestamps(type: :utc_datetime_usec)
    end

    # De twee vragen die hierop gesteld worden: "wie zat er op deze machine" en
    # "waar heeft deze persoon gezeten".
    create index(:console_sessions, [:vps_id, :started_at])
    create index(:console_sessions, [:user_id, :started_at])
  end
end
