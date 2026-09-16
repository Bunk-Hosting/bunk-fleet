defmodule ControlPlane.Repo.Migrations.DropOrphanNodeOwnerEmailIndex do
  use Ecto.Migration

  # Migratie 20260706120000 legde deze index aan voor `Fleet.list_nodes_for_owner/1`.
  # Die functie is bij een eerdere opruiming verdwenen, en `nodes.owner_email`
  # wordt sindsdien alleen nog uitgelezen om te tonen -- er wordt nergens meer op
  # gefilterd. Wat overblijft is een index die bij elke schrijfactie wordt
  # bijgewerkt en nooit gelezen.
  #
  # Omkeerbaar: `down` legt hem terug, mocht het filteren ooit terugkomen.
  def up do
    drop_if_exists index(:nodes, [:owner_email])
  end

  def down do
    create index(:nodes, [:owner_email])
  end
end
