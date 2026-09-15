defmodule ControlPlane.FleetAgentUpdateTest do
  @moduledoc """
  Na een uitrol moeten de nodes te horen krijgen dat ze mogen gaan kijken.
  """
  use ControlPlane.DataCase, async: true

  import Ecto.Query

  alias ControlPlane.Fleet.AgentUpdate
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp region do
    Repo.insert!(%Region{code: "nl-#{System.unique_integer([:positive])}", name: "Regio"})
  end

  defp node(status, r) do
    Repo.insert!(%Node{
      name: "node-#{System.unique_integer([:positive])}",
      status: status,
      hypervisor: :proxmox,
      region_id: r.id
    })
  end

  defp updates_for(node_id) do
    Repo.all(from c in Command, where: c.node_id == ^node_id and c.kind == :update)
  end

  test "online nodes krijgen een update, offline nodes niet" do
    r = region()
    online = node(:online, r)
    offline = node(:offline, r)

    assert AgentUpdate.dispatch_to_online_nodes() == 1

    assert [%Command{kind: :update, status: :pending}] = updates_for(online.id)

    # Een node die uit staat hoeft niets: zijn eigen timer haalt het in zodra hij
    # terug is. Hem nu een commando geven laat alleen werk klaarliggen dat bij
    # terugkomst al achterhaald kan zijn.
    assert [] = updates_for(offline.id)
  end

  test "een node die aan het leeglopen is telt mee" do
    r = region()
    draining = node(:draining, r)

    assert AgentUpdate.dispatch_to_online_nodes() == 1
    assert [%Command{kind: :update}] = updates_for(draining.id)
  end

  test "twee keer uitrollen stapelt geen commando's op" do
    r = region()
    n = node(:online, r)

    assert AgentUpdate.dispatch_to_online_nodes() == 1
    # Dit is het geval dat telt: de control plane herstart een paar keer achter
    # elkaar. Zonder deze controle staat er daarna een rij identieke commando's
    # klaar die de node stuk voor stuk afhandelt.
    assert AgentUpdate.dispatch_to_online_nodes() == 0

    assert [_enkele] = updates_for(n.id)
  end

  test "een afgehandelde update blokkeert de volgende niet" do
    r = region()
    n = node(:online, r)

    assert AgentUpdate.dispatch_to_online_nodes() == 1

    [cmd] = updates_for(n.id)
    cmd |> Ecto.Changeset.change(status: :done) |> Repo.update!()

    assert AgentUpdate.dispatch_to_online_nodes() == 1
    assert length(updates_for(n.id)) == 2
  end

  test "het commando hoort bij de node en niet bij een VPS" do
    r = region()
    n = node(:online, r)
    AgentUpdate.dispatch_to_online_nodes()

    [cmd] = updates_for(n.id)
    assert cmd.vps_id == nil
    assert cmd.payload == %{}
  end
end
