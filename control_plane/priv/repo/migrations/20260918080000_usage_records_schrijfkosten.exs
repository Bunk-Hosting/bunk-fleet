defmodule ControlPlane.Repo.Migrations.UsageRecordsSchrijfkosten do
  use Ecto.Migration

  @moduledoc """
  Minder schrijfwerk per verbruiksregel: de ongebruikte index eraf en de
  willekeurige UUID-sleutel eruit.

  `usage_records` is een tabel waar alleen in wordt geschreven: elke meetronde
  zet er een regel per VPS bij en er wordt nooit een regel gewijzigd. Hij droeg
  vijf B-trees per INSERT, en twee daarvan verdienden hun plek niet.

    * De index op `(node_id, metered_at)` wordt door geen enkele query gebruikt.
      `node_id` wordt wél geschreven -- het hoort bij de geschiedenis van een
      regel -- maar er is nergens een rapport dat op node groepeert. Alles gaat
      via `owner_email` of via de VPS.

    * De primaire sleutel was een willekeurige v4-UUID die nergens wordt
      opgezocht. Er is geen enkele query die een verbruiksregel op zijn id
      ophaalt. Erger dan nutteloos is hij ook nog duur: de rijen worden
      chronologisch geschreven, maar een willekeurige UUID landt op een
      willekeurige bladpagina van de index. Dat is het klassieke recept voor
      schrijfamplificatie en een sleutelindex die niet meer in het geheugen past.

  De natuurlijke sleutel stond er al als unieke index -- `(vps_id, metered_at)`,
  precies de combinatie die een dubbele meting tegenhoudt -- en die wordt nu de
  primaire sleutel. `USING INDEX` hergebruikt de bestaande index in plaats van
  een nieuwe te bouwen, en `DROP COLUMN` is in Postgres administratie en geen
  herschrijving. Deze migratie raakt de tabel dus niet aan.

  Waarom nu: bij twee VPS'en staan hier een paar honderd regels. Bij vijftig
  VPS'en zijn het er bijna een half miljoen per jaar, en dan is dit dezelfde
  wijziging maar met een uitrol die stilstaat terwijl Postgres een tabel
  herschrijft.
  """
  def up do
    drop_if_exists index(:usage_records, [:node_id, :metered_at])

    execute """
    ALTER TABLE usage_records
      DROP CONSTRAINT IF EXISTS usage_records_pkey
    """

    execute "ALTER TABLE usage_records DROP COLUMN IF EXISTS id"

    execute """
    ALTER TABLE usage_records
      ADD CONSTRAINT usage_records_pkey
      PRIMARY KEY USING INDEX usage_records_vps_id_metered_at_index
    """
  end

  def down do
    # De weg terug bestaat, maar hij is niet gratis: een nieuwe UUID-kolom vullen
    # is wél een herschrijving van de tabel. Daarom staat hij hier uitgeschreven
    # en niet als `:irreversible` -- wie hem nodig heeft moet weten wat het kost.
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
