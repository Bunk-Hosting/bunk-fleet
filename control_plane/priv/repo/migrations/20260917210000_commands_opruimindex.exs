defmodule ControlPlane.Repo.Migrations.CommandsOpruimindex do
  use Ecto.Migration

  @moduledoc """
  Een index voor het opruimen van afgehandelde commando's.

  De tabel `commands` werd nooit opgeschoond: elk commando dat ooit naar een node
  is gestuurd staat er nog, met een payload en een resultaat per rij. Dat groeit
  met het aantal VPS'en maal het aantal handelingen, en het enige wat er ooit nog
  naar kijkt is een mens die uitzoekt wat er een keer misging.

  De opruimer zoekt op status plus ouderdom. Zonder index is dat een scan over de
  hele tabel -- precies de tabel die te groot is geworden. Een gedeeltelijke
  index, want alleen afgehandelde rijen komen ooit in aanmerking en de rijen die
  er wél toe doen (pending, delivered) horen niet in een index die alleen voor
  opruimen bestaat.
  """
  def change do
    create index(:commands, [:updated_at],
             where: "status IN ('done', 'failed')",
             name: :commands_afgehandeld_updated_at_index
           )
  end
end
