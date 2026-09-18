defmodule ControlPlane.Repo.Migrations.PakketBandbreedteInMbit do
  use Ecto.Migration

  @moduledoc """
  Bandbreedte wordt een snelheid in plaats van een maandvolume.

  De pakketten beloofden 1, 2 en 5 TB verkeer per maand. Dat was een getal
  waarop niets werd gemeten en niets werd afgedwongen: een klant die tien TB
  door de lijn trok merkte er niets van, en wij ook niet. Een belofte die
  nergens wordt gecontroleerd is geen belofte maar een zin op een pagina.

  Een snelheid is wél waar te maken, want de hypervisor kan hem afdwingen op de
  netwerkkaart van de gast. Starter 200 Mbit, Basic 500 Mbit, Pro 1 Gbit -- een
  bovengrens, geen garantie, en dat is precies wat er te geven valt op een
  gedeelde uplink.

  `bandwidth_tb` blijft in deze stap staan. De draaiende frontend leest die
  kolom nog, en tussen het migreren en het vervangen van de container draait de
  vorige versie op het nieuwe schema. Hij verdwijnt als niemand hem meer leest.
  """
  def up do
    alter table(:packages) do
      add :bandwidth_mbit, :integer, null: false, default: 200
    end

    execute """
    UPDATE packages SET bandwidth_mbit = CASE lower(name)
      WHEN 'starter'  THEN 200
      WHEN 'basic'    THEN 500
      WHEN 'pro'      THEN 1000
      WHEN 'business' THEN 1000
      ELSE 200
    END
    """
  end

  def down do
    alter table(:packages) do
      remove :bandwidth_mbit
    end
  end
end
