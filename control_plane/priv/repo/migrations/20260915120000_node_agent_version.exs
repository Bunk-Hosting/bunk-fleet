defmodule ControlPlane.Repo.Migrations.NodeAgentVersion do
  use Ecto.Migration

  # Welke build van de agent op deze node draait, zoals hij die zelf meldt in
  # zijn heartbeat.
  #
  # Zonder dit is "draait deze node de nieuwe agent?" alleen te beantwoorden door
  # in een gestripte binary naar logregels te zoeken — dat is hier letterlijk
  # gebeurd, en het leverde eerst een verkeerd antwoord op omdat `strings` op de
  # machine ontbrak en de test daardoor stilzwijgend leeg terugkwam.
  #
  # Nullable: een node die nog op een oudere agent draait meldt niets, en dat is
  # geen fout maar precies de informatie die je zoekt.
  def change do
    alter table(:nodes) do
      add :agent_version, :string
    end
  end
end
