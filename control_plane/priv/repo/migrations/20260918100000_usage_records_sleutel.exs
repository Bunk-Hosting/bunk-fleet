defmodule ControlPlane.Repo.Migrations.UsageRecordsSleutel do
  use Ecto.Migration

  @moduledoc """
  Stap twee van twee: de ongebruikte sleutelkolom eruit en de natuurlijke sleutel
  erin, plus de index die niemand gebruikt.

  Sinds de vorige stap stuurt geen enkele draaiende versie `id` nog mee bij een
  INSERT, dus de kolom kan nu weg zonder dat er een moment is waarop de ene
  versie tegen het schema van de andere praat.

  Wat er gebeurt:

    * `(vps_id, metered_at)` wordt de primaire sleutel. Die unieke index stond er
      al -- hij houdt een dubbele meting tegen -- en `USING INDEX` hergebruikt
      hem in plaats van een nieuwe te bouwen.
    * De kolom `id` verdwijnt. In Postgres is dat administratie en geen
      herschrijving van de tabel.
    * De index op `(node_id, metered_at)` verdwijnt. `node_id` wordt geschreven
      omdat het bij de geschiedenis van een regel hoort, maar er is geen enkele
      query die erop zoekt; er is nergens een rapport dat op node groepeert.

  Wat de tabel daarmee per INSERT nog kost: drie B-trees in plaats van vijf, en
  geen willekeurige schrijfpositie meer.
  """
  def up do
    drop_if_exists index(:usage_records, [:node_id, :metered_at])

    execute "ALTER TABLE usage_records DROP CONSTRAINT IF EXISTS usage_records_pkey"
    execute "ALTER TABLE usage_records DROP COLUMN IF EXISTS id"

    execute """
    ALTER TABLE usage_records
      ADD CONSTRAINT usage_records_pkey
      PRIMARY KEY USING INDEX usage_records_vps_id_metered_at_index
    """
  end

  def down do
    # De weg terug bestaat, maar hij is niet gratis: een UUID-kolom terugzetten
    # en vullen is wél een herschrijving van de tabel. Daarom staat hij hier
    # uitgeschreven en niet als `:irreversible` -- wie hem nodig heeft moet weten
    # wat het kost.
    execute "ALTER TABLE usage_records DROP CONSTRAINT IF EXISTS usage_records_pkey"

    execute """
    ALTER TABLE usage_records
      ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid()
    """

    execute "ALTER TABLE usage_records ADD PRIMARY KEY (id)"

    create unique_index(:usage_records, [:vps_id, :metered_at])
    create index(:usage_records, [:node_id, :metered_at])
  end
end
