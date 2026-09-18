defmodule ControlPlane.BlindeNodeFacturatieTest do
  @moduledoc """
  Een node die zijn eigen hypervisor niet kan bevragen, factureert niet door.

  Dit legt een bijwerking vast die niemand had opgeschreven. Vóór het veld
  `capacity_error` bestond, viel zo'n node na twee minuten offline en stopte de
  facturatie vanzelf. Toen de agent bij een storing een heartbeat mét foutmelding
  ging sturen -- om de goede reden dat stilte dubbelzinnig is -- bleef de node
  online met een verse hartslag, en bleef de klant betalen voor machines waarvan
  niemand meer kon zien of ze draaiden.

  De tegenproef staat er ook in: een gezonde node factureert gewoon. Zonder die
  tweede test zou een metering die helemaal niets meer doet er hetzelfde uitzien
  als een geslaagde reparatie.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Billing
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  defp node_met(attrs) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          status: :online,
          last_heartbeat_at: Clock.now(),
          total_vcpu: 32,
          total_ram_mb: 65_536,
          total_disk_gb: 1000,
          available_vcpu: 32,
          available_ram_mb: 65_536,
          available_disk_gb: 1000
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp actieve_vps(node, user) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :active,
      owner_id: user.id,
      owner_email: user.email
    })
    |> Ecto.Changeset.change(%{node_id: node.id})
    |> Repo.insert!()
  end

  test "een node met een capacity_error levert geen verbruiksregels op" do
    user = confirmed_user_fixture()
    node = node_met(%{capacity_error: "proxmox: 401 unauthorized"})
    _vps = actieve_vps(node, user)

    assert Billing.meter_active_vpses() == 0
  end

  test "een gezonde node levert die wel op" do
    user = confirmed_user_fixture()
    node = node_met(%{})
    _vps = actieve_vps(node, user)

    assert Billing.meter_active_vpses() == 1
  end

  test "een lege capacity_error telt als geen fout" do
    # De agent stuurt bij een geslaagde meting een lege string mee in plaats van
    # niets. Zou dat als storing tellen, dan factureerde er nooit meer iets.
    user = confirmed_user_fixture()
    node = node_met(%{capacity_error: ""})
    _vps = actieve_vps(node, user)

    assert Billing.meter_active_vpses() == 1
  end
end
