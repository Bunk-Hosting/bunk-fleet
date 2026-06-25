defmodule ControlPlane.ProvisioningTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Provisioning
  alias ControlPlane.Fleet.{Command, Node, Region, Reservation, Vps}

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

  defp create_attrs(region, overrides \\ %{}) do
    Map.merge(
      %{
        region_id: region.id,
        name: "web-#{System.unique_integer([:positive])}",
        vcpu: 4,
        ram_mb: 8192,
        disk_gb: 100,
        owner_email: "owner@example.com",
        template_id: 9000,
        ssh_keys: ["ssh-ed25519 AAAA..."],
        cloud_init: %{"ciuser" => "bunk-console"},
        ip_config: "ip=10.10.0.10/19,gw=10.10.0.1"
      },
      overrides
    )
  end

  # --- create_vps ------------------------------------------------------------

  describe "create_vps/1" do
    test "places the VPS, enqueues a provision command and decrements capacity" do
      region = insert_region()
      node = insert_node(region)
      attrs = create_attrs(region)

      assert {:ok, %{vps: vps, command: command}} = Provisioning.create_vps(attrs)

      # VPS is provisioning and pinned to the chosen node.
      assert vps.status == :provisioning
      assert vps.node_id == node.id
      assert vps.owner_email == "owner@example.com"

      # A pending provision command exists for the node with the exact payload.
      persisted = Repo.get!(Command, command.id)
      assert persisted.node_id == node.id
      assert persisted.vps_id == vps.id
      assert persisted.kind == :provision
      assert persisted.status == :pending

      assert persisted.payload == %{
               "name" => attrs.name,
               "vcpu" => 4,
               "ram_mb" => 8192,
               "disk_gb" => 100,
               "template_id" => 9000,
               "cloud_init" => %{"ciuser" => "bunk-console"},
               "ssh_keys" => ["ssh-ed25519 AAAA..."],
               "ip_config" => "ip=10.10.0.10/19,gw=10.10.0.1"
             }

      # Node available capacity was decremented by the scheduler.
      reloaded = Repo.get!(Node, node.id)
      assert reloaded.available_vcpu == node.available_vcpu - 4
      assert reloaded.available_ram_mb == node.available_ram_mb - 8192
      assert reloaded.available_disk_gb == node.available_disk_gb - 100

      # A held reservation links the VPS to the node.
      reservation = Repo.get_by!(Reservation, vps_id: vps.id)
      assert reservation.status == :held
      assert reservation.node_id == node.id
    end

    test "marks the VPS :failed and returns :no_capacity when nothing fits" do
      region = insert_region()
      # No nodes in the region at all.

      assert {:error, :no_capacity} = Provisioning.create_vps(create_attrs(region))

      vps = Repo.one!(Vps)
      assert vps.status == :failed
      assert is_nil(vps.node_id)
      refute Repo.exists?(Command)
    end
  end

  # --- apply_result ----------------------------------------------------------

  describe "apply_result/2" do
    setup do
      region = insert_region()
      node = insert_node(region)
      {:ok, %{vps: vps, command: command}} = Provisioning.create_vps(create_attrs(region))
      %{region: region, node: node, vps: vps, command: command}
    end

    test "done activates the VPS and commits the reservation", %{
      node: node,
      vps: vps,
      command: command
    } do
      after_place = Repo.get!(Node, node.id)

      assert {:ok, updated} =
               Provisioning.apply_result(command, %{
                 "status" => "done",
                 "vm_id" => "10101",
                 "ip" => "10.10.0.10",
                 "error" => nil
               })

      assert updated.status == :done
      assert updated.result["vm_id"] == "10101"

      reloaded_vps = Repo.get!(Vps, vps.id)
      assert reloaded_vps.status == :active
      assert reloaded_vps.provider_vm_id == "10101"
      assert reloaded_vps.ip_address == "10.10.0.10"

      reservation = Repo.get_by!(Reservation, vps_id: vps.id)
      assert reservation.status == :committed

      # Capacity stays decremented on success.
      reloaded_node = Repo.get!(Node, node.id)
      assert reloaded_node.available_vcpu == after_place.available_vcpu
      assert reloaded_node.available_ram_mb == after_place.available_ram_mb
      assert reloaded_node.available_disk_gb == after_place.available_disk_gb
    end

    test "failed marks the VPS :failed, releases the reservation and restores capacity",
         %{node: node, vps: vps, command: command} do
      after_place = Repo.get!(Node, node.id)

      assert {:ok, updated} =
               Provisioning.apply_result(command, %{
                 "status" => "failed",
                 "vm_id" => nil,
                 "ip" => nil,
                 "error" => "boom"
               })

      assert updated.status == :failed
      assert updated.result["error"] == "boom"

      reloaded_vps = Repo.get!(Vps, vps.id)
      assert reloaded_vps.status == :failed

      reservation = Repo.get_by!(Reservation, vps_id: vps.id)
      assert reservation.status == :released

      # Freed capacity is added back to the node.
      reloaded_node = Repo.get!(Node, node.id)
      assert reloaded_node.available_vcpu == after_place.available_vcpu + reservation.vcpu
      assert reloaded_node.available_ram_mb == after_place.available_ram_mb + reservation.ram_mb
      assert reloaded_node.available_disk_gb == after_place.available_disk_gb + reservation.disk_gb
    end
  end

  # --- delete_vps ------------------------------------------------------------

  # Drives a VPS through provision -> active so it has a provider_vm_id and a
  # committed reservation, the precondition for deletion.
  defp active_vps(region) do
    {:ok, %{vps: vps, command: command}} = Provisioning.create_vps(create_attrs(region))

    {:ok, _command} =
      Provisioning.apply_result(command, %{
        "status" => "done",
        "vm_id" => "10101",
        "ip" => "10.10.0.10",
        "error" => nil
      })

    Repo.get!(Vps, vps.id)
  end

  describe "delete_vps/1" do
    test "sets the VPS :deleting and enqueues a delete command" do
      region = insert_region()
      _node = insert_node(region)
      vps = active_vps(region)

      assert {:ok, %{vps: deleting, command: command}} = Provisioning.delete_vps(vps.id)

      assert deleting.status == :deleting

      persisted = Repo.get!(Command, command.id)
      assert persisted.node_id == vps.node_id
      assert persisted.vps_id == vps.id
      assert persisted.kind == :delete
      assert persisted.status == :pending
      assert persisted.payload == %{"vm_id" => "10101"}
    end

    test "returns :not_found for an unknown VPS" do
      assert {:error, :not_found} = Provisioning.delete_vps(Ecto.UUID.generate())
    end

    test "returns :no_node for a VPS with no provider VM" do
      region = insert_region()

      vps =
        %Vps{}
        |> Vps.changeset(%{
          name: "orphan",
          region_id: region.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :queued
        })
        |> Repo.insert!()

      assert {:error, :no_node} = Provisioning.delete_vps(vps.id)
    end
  end

  describe "apply_result/2 for a delete command" do
    test "done deletes the VPS, releases the reservation and restores capacity" do
      region = insert_region()
      node = insert_node(region)
      vps = active_vps(region)

      after_provision = Repo.get!(Node, node.id)

      {:ok, %{command: command}} = Provisioning.delete_vps(vps.id)

      assert {:ok, updated} =
               Provisioning.apply_result(command, %{
                 "status" => "done",
                 "vm_id" => "10101",
                 "ip" => nil,
                 "error" => nil
               })

      assert updated.status == :done

      assert Repo.get!(Vps, vps.id).status == :deleted

      reservation = Repo.get_by!(Reservation, vps_id: vps.id)
      assert reservation.status == :released

      reloaded_node = Repo.get!(Node, node.id)
      assert reloaded_node.available_vcpu == after_provision.available_vcpu + reservation.vcpu
      assert reloaded_node.available_ram_mb == after_provision.available_ram_mb + reservation.ram_mb
      assert reloaded_node.available_disk_gb == after_provision.available_disk_gb + reservation.disk_gb
    end

    test "failed records the error but leaves the VPS and reservation intact" do
      region = insert_region()
      _node = insert_node(region)
      vps = active_vps(region)

      {:ok, %{command: command}} = Provisioning.delete_vps(vps.id)

      assert {:ok, updated} =
               Provisioning.apply_result(command, %{
                 "status" => "failed",
                 "vm_id" => nil,
                 "ip" => nil,
                 "error" => "boom"
               })

      assert updated.status == :failed
      assert updated.result["error"] == "boom"

      # VPS stays :deleting (not lost) and its reservation stays committed.
      assert Repo.get!(Vps, vps.id).status == :deleting
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :committed
    end
  end

  # --- command redelivery ----------------------------------------------------

  describe "deliverable_commands_for_node/1" do
    test "redelivers a stale :delivered command but not a fresh one" do
      region = insert_region()
      node = insert_node(region)
      {:ok, %{command: command}} = Provisioning.create_vps(create_attrs(region))

      # Freshly delivered (delivered_at = now) -> not redelivered.
      {:ok, _} = Provisioning.mark_delivered(command)
      refute Enum.any?(Provisioning.deliverable_commands_for_node(node), &(&1.id == command.id))

      # Backdate delivered_at well past the TTL -> becomes deliverable again.
      stale_at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      command
      |> Ecto.Changeset.change(delivered_at: stale_at)
      |> Repo.update!()

      assert Enum.any?(Provisioning.deliverable_commands_for_node(node), &(&1.id == command.id))
    end

    test "always returns :pending commands and never terminal ones" do
      region = insert_region()
      node = insert_node(region)
      {:ok, %{command: pending}} = Provisioning.create_vps(create_attrs(region))

      # Pending is deliverable.
      assert Enum.any?(Provisioning.deliverable_commands_for_node(node), &(&1.id == pending.id))

      # Resolve it; a :done command is never redelivered.
      {:ok, _} =
        Provisioning.apply_result(pending, %{
          "status" => "done",
          "vm_id" => "10101",
          "ip" => "10.10.0.10",
          "error" => nil
        })

      refute Enum.any?(Provisioning.deliverable_commands_for_node(node), &(&1.id == pending.id))
    end
  end
end
