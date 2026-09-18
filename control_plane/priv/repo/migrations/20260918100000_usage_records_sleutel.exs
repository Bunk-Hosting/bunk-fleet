defmodule ControlPlane.Repo.Migrations.UsageRecordsSleutel do
  use Ecto.Migration

  @moduledoc """
  Stap twee van twee: de ongebruikte sleutelkolom eruit, en de index die niemand
  gebruikt.

  Sinds de vorige stap stuurt geen enkele draaiende versie `id` nog mee bij een
  INSERT, dus de kolom kan nu weg zonder dat er een moment is waarop de ene
  versie tegen het schema van de andere praat.

  ## Waarom deze tabel geen primaire sleutel krijgt

  Het lag voor de hand om `(vps_id, metered_at)` te promoveren: die unieke index
  staat er al en houdt een dubbele meting tegen. Dat kan niet, en de reden is
  het bewaren zelf. `vps_id` is `on_delete: :nilify_all` -- verdwijnt een
  VPS-rij echt, dan wordt de verwijzing `NULL` en blijft de verbruiksregel
  staan, want de bedragen moeten zeven jaar mee. Een primaire sleutel eist
  NOT NULL, en die rijen bestaan. (Dat bleek pas tegen de echte database: op een
  verse testdatabase staat geen enkele wees.)

  Dus geen primaire sleutel. Postgres eist er geen, en deze tabel heeft er niets
  aan: er is geen enkele query die één regel opzoekt, en wat beschermd moet
  worden -- niet twee keer hetzelfde tijdvak factureren -- doet de unieke index
  al. In een unieke index zijn NULL-waarden bovendien onderling verschillend,
  dus de wezen zitten elkaar niet in de weg.

  Wat de tabel per INSERT nog kost: twee B-trees in plaats van vijf, en geen
  willekeurige schrijfpositie meer.
  """
  def up do
    drop_if_exists index(:usage_records, [:node_id, :metered_at])
    execute "ALTER TABLE usage_records DROP COLUMN IF EXISTS id"
  end

  def down do
    # De weg terug is geen herstel: een nieuwe UUID-kolom vullen is wél een
    # herschrijving van de tabel, en de oude waarden komen niet terug. Hij staat
    # hier zodat de migratie omkeerbaar is, niet omdat het gratis is.
    execute """
    ALTER TABLE usage_records
      ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid()
    """

    execute "ALTER TABLE usage_records ADD PRIMARY KEY (id)"
    create index(:usage_records, [:node_id, :metered_at])
  end
end
