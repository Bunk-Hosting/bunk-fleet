defmodule ControlPlane.Fleet.SchedulerTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Scheduler

  # --- inline insert helpers -------------------------------------------------

  defp insert_region(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Region #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp insert_node(region, attrs \\ %{}) do
    base = %{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      status: :online,
      last_heartbeat_at: now(),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    }

    attrs = Map.merge(base, attrs)

    # heartbeat_changeset doesn't cast name/region_id, so build the struct via
    # changeset for the associations then force the heartbeat/status fields.
    %Node{}
    |> Node.changeset(attrs)
    |> Ecto.Changeset.put_change(:status, attrs.status)
    |> Ecto.Changeset.put_change(:last_heartbeat_at, attrs.last_heartbeat_at)
    |> Ecto.Changeset.put_change(:available_vcpu, attrs.available_vcpu)
    |> Ecto.Changeset.put_change(:available_ram_mb, attrs.available_ram_mb)
    |> Ecto.Changeset.put_change(:available_disk_gb, attrs.available_disk_gb)
    |> Ecto.Changeset.put_change(:total_vcpu, attrs.total_vcpu)
    |> Ecto.Changeset.put_change(:total_ram_mb, attrs.total_ram_mb)
    |> Ecto.Changeset.put_change(:total_disk_gb, attrs.total_disk_gb)
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp request(region, overrides \\ %{}) do
    Map.merge(%{region_id: region.id, vcpu: 4, ram_mb: 8192, disk_gb: 100}, overrides)
  end

  # --- tests -----------------------------------------------------------------

  test "places into the only fitting node in the region" do
    region = insert_region()
    node = insert_node(region)

    assert {:ok, %{node: placed, reservation: reservation}} =
             Scheduler.place(request(region))

    assert placed.id == node.id
    assert reservation.node_id == node.id
    assert reservation.status == :held
  end

  test "ignores nodes in other regions" do
    region = insert_region()
    other_region = insert_region()
    _other_node = insert_node(other_region)

    assert {:error, :no_capacity} = Scheduler.place(request(region))
  end

  test "ignores offline nodes" do
    region = insert_region()
    _offline = insert_node(region, %{status: :offline})

    assert {:error, :no_capacity} = Scheduler.place(request(region))
  end

  test "returns {:error, :no_capacity} when nothing fits" do
    region = insert_region()

    _too_small =
      insert_node(region, %{
        available_vcpu: 1,
        available_ram_mb: 512,
        available_disk_gb: 10
      })

    assert {:error, :no_capacity} =
             Scheduler.place(request(region, %{vcpu: 8, ram_mb: 16_384, disk_gb: 200}))
  end

  test "decrements available capacity and creates a held reservation" do
    region = insert_region()
    node = insert_node(region)
    req = request(region)

    assert {:ok, %{node: placed, reservation: reservation}} = Scheduler.place(req)

    # Returned node reflects the decrement.
    assert placed.available_vcpu == node.available_vcpu - req.vcpu
    assert placed.available_ram_mb == node.available_ram_mb - req.ram_mb
    assert placed.available_disk_gb == node.available_disk_gb - req.disk_gb

    # Persisted node reflects the decrement.
    reloaded = Repo.get!(Node, node.id)
    assert reloaded.available_vcpu == node.available_vcpu - req.vcpu
    assert reloaded.available_ram_mb == node.available_ram_mb - req.ram_mb
    assert reloaded.available_disk_gb == node.available_disk_gb - req.disk_gb

    # A held reservation was created with the requested spec.
    persisted = Repo.get!(Reservation, reservation.id)
    assert persisted.status == :held
    assert persisted.node_id == node.id
    assert persisted.vcpu == req.vcpu
    assert persisted.ram_mb == req.ram_mb
    assert persisted.disk_gb == req.disk_gb
  end
end
