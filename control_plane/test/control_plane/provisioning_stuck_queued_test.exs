defmodule ControlPlane.ProvisioningStuckQueuedTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp queued_vps(region, age_seconds, attrs \\ %{}) do
    inserted =
      DateTime.utc_now() |> DateTime.add(-age_seconds, :second) |> DateTime.truncate(:second)

    %Vps{}
    |> Vps.changeset(
      Map.merge(
        %{
          name: "v-#{System.unique_integer([:positive])}",
          region_id: region.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :queued
        },
        attrs
      )
    )
    |> Ecto.Changeset.change(%{inserted_at: inserted, updated_at: inserted})
    |> Repo.insert!()
  end

  test "a VPS queued past the grace period with no command is failed" do
    r = region()
    abandoned = queued_vps(r, 3600)

    assert Provisioning.fail_stuck_queued_vpses(600) == 1
    assert Repo.get!(Vps, abandoned.id).status == :failed
  end

  test "a VPS queued moments ago is left alone" do
    # The ordinary path spends a few milliseconds :queued between the insert and
    # the dispatch. Sweeping that would fail every create as it happened.
    r = region()
    fresh = queued_vps(r, 5)

    assert Provisioning.fail_stuck_queued_vpses(600) == 0
    assert Repo.get!(Vps, fresh.id).status == :queued
  end

  test "a VPS with a command behind it is mid-dispatch, not abandoned" do
    r = region()
    node = node_in(r)
    dispatched = queued_vps(r, 3600, %{node_id: node.id})

    Repo.insert!(
      Command.changeset(%Command{}, %{
        node_id: node.id,
        vps_id: dispatched.id,
        kind: :provision,
        status: :pending,
        payload: %{}
      })
    )

    assert Provisioning.fail_stuck_queued_vpses(600) == 0
    assert Repo.get!(Vps, dispatched.id).status == :queued
  end

  test "VPSes in any other state are not touched" do
    r = region()
    node = node_in(r)

    others =
      for status <- [:provisioning, :active, :stopped, :failed, :deleting] do
        v = queued_vps(r, 3600, %{node_id: node.id})
        {:ok, v} = v |> Vps.changeset(%{status: status}) |> Repo.update()
        v
      end

    assert Provisioning.fail_stuck_queued_vpses(600) == 0

    for v <- others do
      assert Repo.get!(Vps, v.id).status == v.status
    end
  end

  test "sweeping twice does not re-count what it already failed" do
    r = region()
    queued_vps(r, 3600)

    assert Provisioning.fail_stuck_queued_vpses(600) == 1
    assert Provisioning.fail_stuck_queued_vpses(600) == 0
  end
end
