defmodule ControlPlane.Repo.Migrations.UsageRecordsIdDefault do
  use Ecto.Migration

  @moduledoc """
  Stap één van twee: de sleutelkolom krijgt een default, zodat hij straks weg kan.

  `usage_records.id` is een willekeurige UUID die nergens wordt opgezocht en die,
  doordat hij willekeurig is, elke chronologisch geschreven rij op een
  willekeurige bladpagina van zijn index laat landen. Hij hoort weg (zie de
  volgende migratie), maar niet in één stap.

  De uitrol draait namelijk eerst de migraties en vervangt dáárna pas de
  container. Tussen die twee momenten draait de vorige versie van de code op het
  nieuwe schema. Die versie vult `id` zelf in bij elke INSERT -- en als de kolom
  dan al weg is, mislukt elke meetronde in dat venster.

  Daarom eerst dit: een default aan de databasekant. Vanaf nu werkt een INSERT
  mét id (de oude code) en zonder id (de nieuwe). Pas als er niemand meer draait
  die hem meestuurt, mag de kolom weg.
  """
  def up do
    execute "ALTER TABLE usage_records ALTER COLUMN id SET DEFAULT gen_random_uuid()"
  end

  def down do
    execute "ALTER TABLE usage_records ALTER COLUMN id DROP DEFAULT"
  end
end
