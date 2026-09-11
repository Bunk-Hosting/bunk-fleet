defmodule ControlPlane.BackupsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Backups
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet.{Command, Node, Region, Vps}

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in(region, status \\ :online) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: status,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp vps(region, node, attrs \\ %{}) do
    %Vps{}
    |> Vps.changeset(
      Map.merge(
        %{
          name: "v-#{System.unique_integer([:positive])}",
          region_id: region.id,
          node_id: node.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active,
          provider_vm_id: "#{100 + System.unique_integer([:positive])}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp backup(vps, attrs) do
    %VpsBackup{}
    |> VpsBackup.changeset(Map.merge(%{vps_id: vps.id, node_id: vps.node_id}, attrs))
    |> Repo.insert!()
  end

  defp commands_for(vps_id, kind) do
    Repo.all(from c in Command, where: c.vps_id == ^vps_id and c.kind == ^kind)
  end

  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
  end

  describe "which VPSes are due" do
    test "an active VPS with no backup is due" do
      r = region()
      machine = vps(r, node_in(r))

      assert %{started: 1, errors: 0} = Backups.run_due()
      assert [%Command{kind: :backup}] = commands_for(machine.id, :backup)
    end

    test "one backed up recently is not" do
      r = region()
      machine = vps(r, node_in(r))
      backup(machine, %{status: :done, started_at: ago(60), finished_at: ago(30)})

      assert %{started: 0} = Backups.run_due()
      assert [] = commands_for(machine.id, :backup)
    end

    test "one backed up longer ago than the interval is due again" do
      r = region()
      machine = vps(r, node_in(r))

      backup(machine, %{
        status: :done,
        started_at: ago(Backups.interval_seconds() + 3600),
        finished_at: ago(Backups.interval_seconds() + 3500)
      })

      assert %{started: 1} = Backups.run_due()
    end

    test "one whose backup is still running is left alone, however old" do
      # A second vzdump of the same guest would fight the first for the node's
      # disk, and the customer would feel both.
      r = region()
      machine = vps(r, node_in(r))
      backup(machine, %{status: :running, started_at: ago(Backups.interval_seconds() * 5)})

      assert %{started: 0} = Backups.run_due()
    end

    test "a failed backup does not stop the next one being due" do
      r = region()
      machine = vps(r, node_in(r))

      backup(machine, %{
        status: :failed,
        error: "storage full",
        started_at: ago(Backups.interval_seconds() + 60),
        finished_at: ago(Backups.interval_seconds() + 30)
      })

      assert %{started: 1} = Backups.run_due()
    end

    test "a VPS that is not running is not backed up" do
      r = region()
      node = node_in(r)
      vps(r, node, %{status: :stopped})
      vps(r, node, %{status: :failed})

      assert %{started: 0} = Backups.run_due()
    end

    test "a VPS with no guest behind it yet is skipped" do
      r = region()
      vps(r, node_in(r), %{provider_vm_id: nil, status: :active})

      assert %{started: 0} = Backups.run_due()
    end

    test "a VPS on an offline node is skipped, one on a draining node is not" do
      # Draining means closed to new VPSes, not abandoned: what is still running
      # there still deserves its backup.
      r = region()
      vps(r, node_in(r, :offline))
      on_draining = vps(r, node_in(r, :draining))

      assert %{started: 1} = Backups.run_due()
      assert [_] = commands_for(on_draining.id, :backup)
    end
  end

  describe "recording what the node reported" do
    test "a successful backup records the archive" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/vzdump-qemu-106-2026_09_11.vma.zst",
          "size_bytes" => 1_234_567
        })

      assert saved.status == :done
      assert saved.size_bytes == 1_234_567
      refute is_nil(saved.finished_at)
    end

    test "a failure is written down, not dropped" do
      # "The last three nightly backups failed" is the most useful thing this
      # table can say, and it can only say it if failures are rows.
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{"status" => "failed", "error" => "storage full"})

      assert saved.status == :failed
      assert saved.error == "storage full"
      assert [^saved] = Backups.list_for_vps(machine.id)
    end

    test "a size reported as a string is still a size" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/x.vma.zst",
          "size_bytes" => "999"
        })

      assert saved.size_bytes == 999
    end

    test "nonsense where a size should be is no size, not a crash" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/x.vma.zst",
          "size_bytes" => "enormous"
        })

      assert is_nil(saved.size_bytes)
    end
  end

  describe "retention" do
    test "keeps the newest and queues deletion of the rest" do
      r = region()
      machine = vps(r, node_in(r))

      for i <- 1..(Backups.keep() + 2) do
        backup(machine, %{
          status: :done,
          volid: "local:backup/vzdump-#{i}.vma.zst",
          started_at: ago(i * 100),
          finished_at: ago(i * 100 - 10)
        })
      end

      {:ok, pruned} = Backups.prune(machine.id)

      assert pruned == 2
      assert length(commands_for(machine.id, :delete_backup)) == 2
    end

    test "a failed backup is never pruned into a deletion command" do
      # There is no archive to delete, and a deletion command naming nothing
      # would fail on the node forever.
      r = region()
      machine = vps(r, node_in(r))

      for i <- 1..(Backups.keep() + 2) do
        backup(machine, %{status: :failed, error: "nope", started_at: ago(i * 100)})
      end

      assert {:ok, 0} = Backups.prune(machine.id)
      assert [] = commands_for(machine.id, :delete_backup)
    end

    test "the row survives until the node confirms the archive is gone" do
      r = region()
      machine = vps(r, node_in(r))

      kept =
        for i <- 1..(Backups.keep() + 1) do
          backup(machine, %{
            status: :done,
            volid: "local:backup/vzdump-#{i}.vma.zst",
            started_at: ago(i * 100),
            finished_at: ago(i * 100 - 10)
          })
        end

      {:ok, 1} = Backups.prune(machine.id)

      # Still listed: the row is the only handle on a file that still exists.
      assert length(Backups.list_for_vps(machine.id)) == length(kept)

      oldest = List.last(kept)
      {:ok, _} = Backups.forget(oldest.id)
      assert length(Backups.list_for_vps(machine.id)) == length(kept) - 1
    end

    test "forgetting one that is already gone is not an error" do
      assert {:ok, :already_gone} = Backups.forget(Ecto.UUID.generate())
    end
  end
end
