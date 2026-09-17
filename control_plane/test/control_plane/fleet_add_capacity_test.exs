defmodule ControlPlane.FleetAddCapacityTest do
  @moduledoc """
  Capaciteit teruggeven mag het totaal van de node niet passeren.

  Op 17 september 2026 gebeurde dat wel: sinds `available_*` per heartbeat wordt
  afgeleid uit wat de node vrij meldt min de lopende reserveringen, is die
  teruggave overbodig zodra er een heartbeat langs is geweest -- de vrijgegeven
  reservering telt dan al niet meer mee. Er nog eens bij optellen kwam uit op
  7 vCPU vrij op een node met er 6, de check-constraint weigerde dat, en de hele
  transactie rolde terug. De reservering bleef daardoor vastzitten.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp fleet_node(attrs) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    Repo.insert!(
      struct(
        %Node{
          name: "node-#{System.unique_integer([:positive])}",
          region_id: region.id,
          hypervisor: :proxmox,
          status: :online,
          last_heartbeat_at: ControlPlane.Clock.now(),
          total_vcpu: 6,
          total_ram_mb: 10_240,
          total_disk_gb: 225
        },
        attrs
      )
    )
  end

  defp terug(n, vcpu, ram, disk) do
    {:ok, _} =
      Node.add_capacity(Repo, %{node_id: n.id, vcpu: vcpu, ram_mb: ram, disk_gb: disk})

    Repo.get!(Node, n.id)
  end

  test "geeft capaciteit terug binnen het totaal" do
    n = fleet_node(%{available_vcpu: 2, available_ram_mb: 4096, available_disk_gb: 100})

    na = terug(n, 1, 1024, 20)

    assert na.available_vcpu == 3
    assert na.available_ram_mb == 5120
    assert na.available_disk_gb == 120
  end

  test "topt af op het totaal in plaats van de transactie te laten falen" do
    # Dit is het geval dat op productie omviel. De heartbeat had available_* al
    # teruggerekend naar wat de node vrij meldt, dus de teruggave kwam bovenop
    # iets dat er al in zat.
    n = fleet_node(%{available_vcpu: 6, available_ram_mb: 10_240, available_disk_gb: 160})

    na = terug(n, 1, 1024, 20)

    assert na.available_vcpu == 6
    assert na.available_ram_mb == 10_240
    assert na.available_disk_gb == 180
  end

  test "laat een node die nog nooit heeft gemeld met rust" do
    # NULL betekent "niets gemeld", niet "nul vrij". Daar een getal van maken zou
    # een node plaatsbaar maken waarvan niemand weet wat hij kan.
    n = fleet_node(%{available_vcpu: nil, available_ram_mb: nil, available_disk_gb: nil})

    na = terug(n, 1, 1024, 20)

    assert is_nil(na.available_vcpu)
    assert is_nil(na.available_ram_mb)
    assert is_nil(na.available_disk_gb)
  end

  test "zonder bekend totaal wordt er niet afgetopt" do
    # Een node die capaciteit heeft gemeld maar geen totaal is een rare toestand;
    # aftoppen op een onbekend totaal zou hem op nul zetten.
    n =
      fleet_node(%{
        total_vcpu: nil,
        total_ram_mb: nil,
        total_disk_gb: nil,
        available_vcpu: 2,
        available_ram_mb: 4096,
        available_disk_gb: 100
      })

    na = terug(n, 1, 1024, 20)

    assert na.available_vcpu == 3
    assert na.available_ram_mb == 5120
    assert na.available_disk_gb == 120
  end
end
