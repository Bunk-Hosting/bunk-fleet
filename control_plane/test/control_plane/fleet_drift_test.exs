defmodule ControlPlane.FleetDriftTest do
  @moduledoc """
  De administratie tegen de werkelijkheid houden.

  Het control plane is de bron van waarheid over een VPS, en dat is een goede
  keuze -- maar niemand vergeleek die waarheid ooit met wat er werkelijk op een
  node draait. Twee richtingen kosten geld: een VPS die wij factureren en die
  niet bestaat, en een gast op de node die wij niet kennen en die capaciteit eet
  die de scheduler denkt te kunnen verkopen.

  Wat hier vooral vastligt is wat er NIET gebeurt: er wordt niets automatisch
  opgeruimd. Dat zou berusten op de aanname dat het antwoord van de node klopt,
  en juist dat is wat gecontroleerd wordt.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Drift
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp node_met_status(status \\ :online) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{status: status, last_heartbeat_at: ControlPlane.Clock.now()})
    |> Repo.insert!()
  end

  defp vps_op(node, vm_id, status \\ :active) do
    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(%{status: status, node_id: node.id, provider_vm_id: vm_id})
    |> Repo.insert!()
  end

  describe "vergelijken" do
    test "een VPS die op de node niet bestaat wordt gemeld" do
      node = node_met_status()
      vps_op(node, "2001")
      vps_op(node, "2002")

      %{verdwenen: verdwenen} = Drift.compare(node.id, ["2001"])

      assert [%{vm_id: "2002"}] = verdwenen
    end

    test "en wordt NIET opgeruimd" do
      # Automatisch verwijderen zou berusten op de aanname dat het antwoord van
      # de node klopt. Een node die een half antwoord geeft zou dan een vloot
      # wissen.
      node = node_met_status()
      vps = vps_op(node, "2002")

      Drift.compare(node.id, [])

      bijgewerkt = Repo.get!(Vps, vps.id)
      assert bijgewerkt.status == :active
      assert bijgewerkt.provider_vm_id == "2002"
    end

    test "een gast die wij niet kennen wordt gemeld" do
      node = node_met_status()
      vps_op(node, "2001")

      %{onbekend: onbekend} = Drift.compare(node.id, ["2001", "9000", "115"])

      assert Enum.sort(onbekend) == ["115", "9000"]
    end

    test "een verwijderde VPS telt niet mee als verdwenen" do
      # Die hoort niet meer op de node te staan; hem missen is het goede gedrag.
      node = node_met_status()
      vps_op(node, "2003", :deleted)

      assert %{verdwenen: [], onbekend: []} = Drift.compare(node.id, [])
    end

    test "een VPS zonder provider-id telt niet mee" do
      # Nog niet uitgerold: er valt niets te vergelijken.
      node = node_met_status()

      %Vps{}
      |> Vps.changeset(%{
        name: "nieuw",
        region_id: node.region_id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20
      })
      |> Ecto.Changeset.change(%{status: :queued, node_id: node.id})
      |> Repo.insert!()

      assert %{verdwenen: [], onbekend: []} = Drift.compare(node.id, [])
    end

    test "de VPS van een andere node blijft buiten beschouwing" do
      een = node_met_status()
      twee = node_met_status()
      vps_op(twee, "2001")

      assert %{verdwenen: []} = Drift.compare(een.id, [])
    end
  end

  describe "aanvragen" do
    test "elke online node krijgt een inventarisatie" do
      een = node_met_status()
      twee = node_met_status(:draining)
      _offline = node_met_status(:offline)

      assert Drift.request_all() == 2

      for node <- [een, twee] do
        assert Repo.exists?(
                 from c in Command,
                   where: c.node_id == ^node.id and c.kind == :inventory and c.status == :pending
               )
      end
    end

    test "geen tweede zolang de eerste openstaat" do
      # Die zou in de rij achter de eerste belanden en hetzelfde antwoord
      # opleveren, terwijl de agent commando's één voor één verwerkt.
      node = node_met_status()

      assert Drift.request_all() == 1
      assert Drift.request_all() == 0

      assert Repo.aggregate(
               from(c in Command, where: c.node_id == ^node.id and c.kind == :inventory),
               :count
             ) == 1
    end
  end
end
