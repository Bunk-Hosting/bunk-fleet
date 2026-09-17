defmodule ControlPlane.Repo.Migrations.IdempotencyKeys do
  @moduledoc """
  Een bestelling die twee keer binnenkomt mag één VPS opleveren.

  Een klant die na een time-out op "bestellen" drukt stuurt hetzelfde verzoek
  nog een keer. Er is niets dat die twee aan elkaar knoopt, dus het wordt twee
  machines en twee afschrijvingen -- en de tweede ontdekt hij pas op zijn
  rekening.

  De sleutel komt van de client en wordt per gebruiker uniek afgedwongen door de
  database. Niet in het geheugen van het proces: een uitrol tussen de twee
  verzoeken is precies het moment waarop dit gebeurt.
  """
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false, size: 200

      # Waar de sleutel voor gold. Nu alleen "vps_create", maar een sleutel van
      # het ene endpoint mag nooit een ander endpoint afdekken.
      add :scope, :string, null: false

      # Het resultaat, zodra er een is. NULL betekent "nog bezig".
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "in_flight"

      timestamps(type: :utc_datetime)
    end

    # De hele bescherming hangt hieraan: twee gelijktijdige verzoeken met
    # dezelfde sleutel kunnen niet allebei een rij aanmaken.
    create unique_index(:idempotency_keys, [:user_id, :scope, :key])
  end
end
