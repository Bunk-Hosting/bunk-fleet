defmodule ControlPlane.FleetReportedCapacityTest do
  @moduledoc """
  De tweede horde bij plaatsing: wat de agent zelf nog vrij ziet.

  `available_*` is van de scheduler en beschermt tegen overboeken door
  gelijktijdige bestellingen. Maar dat cijfer begint bij het totaal van de
  machine en weet niets van wat daar al op draaide voordat Bunk er was. Op de
  eerste node scheelde dat zeven gigabyte: de scheduler dacht 10,8 GB vrij te
  hebben terwijl de agent er 0,9 meldde. Een bestelling van 8 GB zou daar
  geplaatst zijn — op de machine waar de control plane zelf op draait.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Scheduler
  alias ControlPlane.Repo

  defp regio,
    do: Repo.insert!(%Region{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})

  defp node(r, attrs) do
    Repo.insert!(
      struct(
        %Node{
          name: "node-#{System.unique_integer([:positive])}",
          region_id: r.id,
          hypervisor: :proxmox,
          status: :online,
          last_heartbeat_at: ControlPlane.Clock.now(),
          total_vcpu: 4,
          total_ram_mb: 11_843,
          total_disk_gb: 94,
          available_vcpu: 4,
          available_ram_mb: 11_843,
          available_disk_gb: 94
        },
        attrs
      )
    )
  end

  defp verzoek(r, ram_mb),
    do: %{region_id: r.id, vcpu: 1, ram_mb: ram_mb, disk_gb: 20}

  test "een node die minder meldt dan de boekhouding denkt, wordt overgeslagen" do
    r = regio()
    node(r, %{reported_avail_ram_mb: 900, reported_avail_vcpu: 4, reported_avail_disk_gb: 70})

    # De boekhouding zegt 11.843 MB vrij, de agent zegt 900. Acht gigabyte past
    # in het eerste getal en niet in het tweede, en dat tweede is de machine.
    assert {:error, :no_capacity} = Scheduler.place(verzoek(r, 8192))
  end

  test "wat in beide past wordt gewoon geplaatst" do
    r = regio()

    n =
      node(r, %{reported_avail_ram_mb: 6211, reported_avail_vcpu: 3, reported_avail_disk_gb: 70})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 1024))
    assert gekozen.id == n.id
  end

  test "een node die nog niets gemeld heeft blijft bruikbaar" do
    r = regio()
    # nil betekent "geen informatie", niet "geen ruimte". Een node blokkeren op
    # een ontbrekend cijfer zou een werkende machine onbruikbaar maken — precies
    # de fout die een NULL met een eigen betekenis hier eerder aanrichtte.
    n =
      node(r, %{reported_avail_ram_mb: nil, reported_avail_vcpu: nil, reported_avail_disk_gb: nil})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 2048))
    assert gekozen.id == n.id
  end

  test "de scheduler kiest de node die er in werkelijkheid ruimte voor heeft" do
    r = regio()
    # Beide zien er in de boekhouding identiek uit; alleen wat de agents melden
    # verschilt. Zonder de tweede horde zou de keuze een muntworp zijn.
    vol =
      node(r, %{reported_avail_ram_mb: 512, reported_avail_vcpu: 1, reported_avail_disk_gb: 70})

    leeg =
      node(r, %{reported_avail_ram_mb: 9000, reported_avail_vcpu: 4, reported_avail_disk_gb: 70})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 4096))
    assert gekozen.id == leeg.id
    refute gekozen.id == vol.id
  end

  test "de heartbeat schrijft de gemelde cijfers, maar niet de boekhouding" do
    r = regio()
    n = node(r, %{available_ram_mb: 5000})

    {:ok, bijgewerkt} =
      Fleet.mark_online_heartbeat(n, %{
        "total_vcpu" => 4,
        "total_ram_mb" => 11_843,
        "total_disk_gb" => 94,
        "reported_avail_vcpu" => 2,
        "reported_avail_ram_mb" => 3651,
        "reported_avail_disk_gb" => 70
      })

    assert bijgewerkt.reported_avail_ram_mb == 3651

    # Dit is de kern: een heartbeat mag available_* niet aanraken. Zou hij dat
    # wel doen, dan zien twee bestellingen tussen twee heartbeats allebei
    # dezelfde ruimte en boeken ze de node samen over.
    assert bijgewerkt.available_ram_mb == 5000
  end
end
