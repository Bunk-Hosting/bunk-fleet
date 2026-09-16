defmodule ControlPlane.Repo.Migrations.NodeReportedCapacity do
  use Ecto.Migration

  # Wat de agent bij elke heartbeat als vrij meldt, los van de boekhouding van
  # de scheduler.
  #
  # `available_*` is en blijft van de scheduler: die telt af bij plaatsing en
  # terug bij verwijdering, onder een rijvergrendeling, zodat twee gelijktijdige
  # bestellingen een node niet kunnen overboeken. Dat werkt — maar het cijfer
  # begint bij het totale geheugen van de machine en weet niets van wat daar al
  # op draaide voordat Bunk er was. Op de eerste node scheelde dat 7 GB: de
  # scheduler dacht 10,8 GB vrij te hebben terwijl de agent 0,9 GB meldde en de
  # host er werkelijk 3,6 GB onvergeven had. Een bestelling van 8 GB zou daar
  # geplaatst zijn, op een machine waar de control plane zelf op draait.
  #
  # De agent overschrijven met zijn eigen cijfer zou de bescherming tegen
  # overboeken weghalen (twee plaatsingen tussen twee heartbeats zien allebei
  # hetzelfde getal). Daarom een tweede kolom: de scheduler eist dat een node
  # in béíde past.
  #
  # Nullable, en NULL betekent "nog niets gemeld" — een node die nog geen
  # heartbeat heeft gestuurd of een agent van vóór deze versie draait. Dat mag
  # geen plaatsing blokkeren, dus de scheduler slaat de eis dan over.
  def change do
    alter table(:nodes) do
      add :reported_avail_vcpu, :integer
      add :reported_avail_ram_mb, :integer
      add :reported_avail_disk_gb, :integer
    end
  end
end
