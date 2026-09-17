defmodule ControlPlane.Repo.Migrations.VpsConsoleKey do
  @moduledoc """
  Een eigen consolesleutel per VPS.

  Allebei nullable, en dat blijft zo. Een VPS die er al stond heeft geen eigen
  sleutel en gebruikt de gedeelde; `NULL` betekent hier dus "van vóór deze
  wijziging" en niet "stuk". Verplicht maken zou betekenen dat de bestaande
  rijen iets moeten krijgen wat nooit in hun `authorized_keys` is gezet -- een
  sleutel die nergens op past.
  """
  use Ecto.Migration

  def change do
    alter table(:vpses) do
      # De privésleutel, versleuteld met de sleutel uit de omgeving. Binary en
      # geen text: het is ciphertext, geen leesbare PEM.
      add :console_key_sealed, :binary
      # De publieke kant zoals hij in authorized_keys van deze VPS staat.
      add :console_key_public, :text
    end
  end
end
