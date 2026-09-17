defmodule ControlPlane.Repo.Migrations.NodeSettings do
  use Ecto.Migration

  # De instellingen van een node stonden alleen in het service-bestand op de
  # machine zelf: wijzigen betekende inloggen, een bestand aanpassen en de agent
  # herstarten. Dat maakt ze onzichtbaar voor wie de node bezit maar niet bij de
  # machine kan, en het maakt van elke aanpassing een ingreep.
  #
  # Ze staan nu hier, zodat de eigenaar ze vanuit het dashboard wijzigt en de
  # agent ze bij zijn eerstvolgende heartbeat oppikt. NULL betekent overal
  # "niet ingesteld": de agent houdt dan wat er lokaal staat, zodat een node die
  # nog nooit is aangeraakt zich niet ineens anders gedraagt.
  def change do
    alter table(:nodes) do
      # Hoeveel van de machine naar de VPS-pool gaat. NULL of 0 = alles.
      add :offer_vcpu, :integer
      add :offer_ram_mb, :integer
      add :offer_disk_gb, :integer

      # Het VMID-blok dat van Bunk is, zodat klant-VPS'en niet tussen de eigen
      # machines van de operator komen te staan.
      add :vmid_min, :integer
      add :vmid_max, :integer

      # Hoeveel vCPU's per fysieke core worden uitgedeeld. RAM en schijf worden
      # nooit overboekt; een vCPU is een aandeel in tijd.
      add :vcpu_oversubscribe, :integer

      # Hoe een gast op de hypervisor gaat heten. Moet het unieke deel bevatten,
      # anders kan de agent twee VPS'en niet uit elkaar houden -- zie de
      # validatie in Fleet.Node.
      add :guest_name_pattern, :string
    end
  end
end
