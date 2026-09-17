defmodule ControlPlane.FleetRegionsTest do
  @moduledoc """
  Regio's zijn de locaties waar een klant tussen kiest.

  Het `enabled`-veld bestond al maar werd nergens gebruikt: een schakelaar die
  niets deed. Hij hoort te betekenen wat een beheerder ervan verwacht — een
  locatie die wordt afgebouwd neemt geen nieuwe VPS'en meer aan, terwijl wat er
  draait gewoon blijft draaien. Hetzelfde idee als een node die draint.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp regio(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Regio #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp fleet_node(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      total_vcpu: 16,
      total_ram_mb: 32_768,
      total_disk_gb: 500,
      available_vcpu: 16,
      available_ram_mb: 32_768,
      available_disk_gb: 500,
      reported_avail_vcpu: 16,
      reported_avail_ram_mb: 32_768,
      reported_avail_disk_gb: 500
    })
    |> Repo.insert!()
  end

  defp verzoek, do: %{vcpu: 1, ram_mb: 1024, disk_gb: 20}

  describe "een uitgeschakelde regio" do
    test "staat niet in de lijst waar de klant uit kiest" do
      aan = regio()
      uit = regio(%{enabled: false})
      fleet_node(aan)
      fleet_node(uit)

      codes = Fleet.available_regions() |> Enum.map(& &1.code)

      assert aan.code in codes
      refute uit.code in codes
    end

    test "wordt niet automatisch gekozen" do
      # Automatisch plaatsen mag niet uitkomen op een locatie die bewust dicht is.
      uit = regio(%{enabled: false})
      fleet_node(uit)

      assert {:error, :no_capacity} = Fleet.auto_region_id(verzoek())
    end

    test "staat wel in de keuzelijst van de eigenaar die er een node heeft" do
      # Anders zou het keuzeveld in het dashboard een andere locatie aanwijzen
      # dan waar de machine staat, en zou een onbedoelde verhuizing één klik zijn.
      uit = regio(%{enabled: false})
      n = fleet_node(uit)

      refute uit.code in (Fleet.selectable_regions() |> Enum.map(& &1.code))
      assert uit.code in (Fleet.selectable_regions([n.region_id]) |> Enum.map(& &1.code))
    end

    test "een node zonder regio laat de lijst met rust" do
      # `nil` komt hier langs zodra een node nog geen locatie heeft; die hoort de
      # query niet te laten struikelen en niets extra's binnen te halen.
      aan = regio()
      uit = regio(%{enabled: false})

      codes = Fleet.selectable_regions([nil]) |> Enum.map(& &1.code)

      assert aan.code in codes
      refute uit.code in codes
    end

    test "houdt een ingeschakelde regio wel bereikbaar" do
      aan = regio()
      uit = regio(%{enabled: false})
      fleet_node(aan)
      fleet_node(uit)

      assert {:ok, gekozen} = Fleet.auto_region_id(verzoek())
      assert gekozen == aan.id
    end
  end

  describe "een node verplaatsen naar een andere regio" do
    setup do
      {:ok, u} =
        ControlPlane.Accounts.register_user(%{
          email: "verhuis-#{System.unique_integer([:positive])}@bunk.test",
          password: "Str0ngPassphrase!42"
        })

      van = regio()
      naar = regio()
      n = fleet_node(van)
      n = Repo.update!(Ecto.Changeset.change(n, owner_id: u.id))

      %{user: u, node: n, van: van, naar: naar}
    end

    defp vps_op(node, region, status) do
      %Vps{}
      |> Vps.changeset(%{
        name: "vps-#{System.unique_integer([:positive])}",
        region_id: region.id,
        node_id: node.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20
      })
      |> Ecto.Changeset.put_change(:status, status)
      |> Repo.insert!()
    end

    test "de VPS'en gaan mee", %{user: u, node: n, van: van, naar: naar} do
      # Een regio beschrijft waar de machine fysiek staat. Laat je de VPS'en
      # achter in de oude regio, dan liegt het label bij elke klant die het
      # opvraagt.
      draait = vps_op(n, van, :active)

      assert {:ok, bijgewerkt} = Fleet.move_node_to_region(n.id, u, naar.id)
      assert bijgewerkt.region_id == naar.id
      assert Repo.get!(Vps, draait.id).region_id == naar.id
    end

    test "een verwijderde VPS blijft waar hij stond", %{user: u, node: n, van: van, naar: naar} do
      # Die draait nergens meer; zijn geschiedenis hoort te blijven kloppen.
      weg = vps_op(n, van, :deleted)

      assert {:ok, _} = Fleet.move_node_to_region(n.id, u, naar.id)
      assert Repo.get!(Vps, weg.id).region_id == van.id
    end

    test "een ander dan de eigenaar mag het niet", %{node: n, naar: naar} do
      {:ok, vreemde} =
        ControlPlane.Accounts.register_user(%{
          email: "vreemde-#{System.unique_integer([:positive])}@bunk.test",
          password: "Str0ngPassphrase!42"
        })

      assert {:error, :forbidden} = Fleet.move_node_to_region(n.id, vreemde, naar.id)
    end

    test "een regio die niet bestaat wordt geweigerd", %{user: u, node: n, van: van} do
      assert {:error, :unknown_region} =
               Fleet.move_node_to_region(n.id, u, Ecto.UUID.generate())

      assert Repo.get!(Node, n.id).region_id == van.id
    end
  end

  describe "beheer" do
    test "toont per regio hoeveel nodes erin staan" do
      # Een regio zonder nodes kan niets leveren en verschijnt niet in het
      # bestelscherm. Dat verschil hoort zichtbaar te zijn.
      vol = regio()
      leeg = regio()
      fleet_node(vol)
      fleet_node(vol)

      rijen = Fleet.list_regions_with_counts() |> Map.new(&{&1.region.id, &1.node_count})

      assert rijen[vol.id] == 2
      assert rijen[leeg.id] == 0
    end

    test "hernoemen laat de code met rust" do
      # De code staat in bestelhistorie en in de installatie-instructies van elke
      # node in die regio; die veranderen zou verwijzingen breken.
      r = regio()

      assert {:ok, bijgewerkt} =
               Fleet.update_region(r.id, %{"name" => "Amsterdam", "code" => "xx"})

      assert bijgewerkt.name == "Amsterdam"
      assert bijgewerkt.code == r.code
    end

    test "aan- en uitzetten werkt" do
      r = regio()

      assert {:ok, %Region{enabled: false}} = Fleet.update_region(r.id, %{"enabled" => false})
      assert {:ok, %Region{enabled: true}} = Fleet.update_region(r.id, %{"enabled" => true})
    end

    test "een regio die niet bestaat geeft not_found" do
      assert {:error, :not_found} = Fleet.update_region(Ecto.UUID.generate(), %{"name" => "X"})
    end

    test "twee regio's met dezelfde code kan niet" do
      r = regio()

      assert {:error, changeset} = Fleet.create_region(%{code: r.code, name: "Dubbel"})
      assert Keyword.has_key?(changeset.errors, :code)
    end
  end
end
