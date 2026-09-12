defmodule ControlPlane.Backups do
  @moduledoc """
  Scheduled backups of customer VPS disks.

  ## What this covers, and what it does not

  These are node-local `vzdump` archives: the node writes them to its own
  storage. That protects against the common failure — a customer broke their own
  machine and wants yesterday back — and not against the rare one, a node losing
  the disk that holds both the VPS and its backups. Both halves are worth
  saying out loud, because "we back up your VPS" means different things to a
  customer and to whoever has to honour it.

  The control plane never holds the bytes. It records that an archive exists and
  where, decides when the next one is due, and prunes the oldest past the
  retention count. Everything physical happens on the node.

  ## Why a command rather than a request

  A backup is dispatched the same way provisioning is: a `:backup` command on the
  node's poll. It can take minutes, it can fail halfway, and the node may be
  asleep when it is due — all of which the command pipeline already handles, and
  none of which an HTTP call would.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias Ecto.Multi

  @doc "How often each VPS is backed up, unless configured otherwise."
  def interval_seconds, do: Application.get_env(:control_plane, :backup_interval_seconds, 86_400)

  @doc """
  How many archives to keep per VPS.

  Deliberately small: these sit on the node's own disk next to the VPSes they
  protect, so retention is bounded by the storage a node can spare, not by what
  would be nice to have.
  """
  def keep, do: Application.get_env(:control_plane, :backup_keep, 2)

  @doc """
  Dispatches a backup for every VPS that is due one, and returns a summary.

  "Due" means active, on an online node, with a recognised provider VM, and with
  no backup started within `interval_seconds`. A VPS with a backup already in
  flight is skipped rather than queued again — a second `vzdump` of the same
  guest would contend with the first for the node's disk.
  """
  def run_due(now \\ DateTime.utc_now()) do
    due = due_vpses(now)

    Enum.reduce(due, %{started: 0, errors: 0}, fn vps, acc ->
      case start_backup(vps) do
        {:ok, _} ->
          %{acc | started: acc.started + 1}

        {:error, reason} ->
          Logger.error("backup for vps #{vps.id} could not be dispatched: #{inspect(reason)}")
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  @doc """
  Queues one backup of `vps`: a row to track it and a command to do it.

  Both in one transaction, because a row with no command is a backup that never
  runs and a command with no row is one nobody can find.
  """
  def start_backup(%Vps{} = vps) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.insert(:backup, fn _ ->
      VpsBackup.changeset(%VpsBackup{}, %{
        vps_id: vps.id,
        node_id: vps.node_id,
        status: :running,
        started_at: now
      })
    end)
    |> Multi.insert(:command, fn %{backup: backup} ->
      Command.changeset(%Command{}, %{
        node_id: vps.node_id,
        vps_id: vps.id,
        kind: :backup,
        status: :pending,
        payload: %{"vm_id" => vps.provider_vm_id, "backup_id" => backup.id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{backup: backup}} -> {:ok, backup}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Records what the node reported, and prunes anything past the retention count.

  A failure is written down rather than dropped: "the last three nightly backups
  failed" is the single most useful thing this table can tell anyone, and it can
  only tell it if failures are rows too.
  """
  def record_result(backup_id, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get(VpsBackup, backup_id) do
      nil ->
        {:error, :not_found}

      %VpsBackup{} = backup ->
        attrs =
          case result do
            %{"status" => "done"} = r ->
              %{
                status: :done,
                volid: r["volid"],
                size_bytes: sane_size(r["size_bytes"]),
                finished_at: now
              }

            r ->
              %{status: :failed, error: to_string(r["error"] || "unknown"), finished_at: now}
          end

        with {:ok, saved} <- backup |> VpsBackup.changeset(attrs) |> Repo.update() do
          if saved.status == :done, do: prune(saved.vps_id)
          {:ok, saved}
        end
    end
  end

  @doc """
  Queues deletion of every archive past the newest `keep/0` for this VPS.

  The rows go when the node confirms the archive did; deleting the row first
  would lose the only handle on a file still taking up the node's disk.
  """
  def prune(vps_id) do
    stale =
      Repo.all(
        from b in VpsBackup,
          where: b.vps_id == ^vps_id and b.status == :done and not is_nil(b.volid),
          order_by: [desc: b.finished_at],
          offset: ^keep()
      )

    Enum.each(stale, fn backup ->
      vps = Repo.get(Vps, vps_id)

      if vps && backup.node_id do
        Repo.insert(
          Command.changeset(%Command{}, %{
            node_id: backup.node_id,
            vps_id: vps_id,
            kind: :delete_backup,
            status: :pending,
            payload: %{"volid" => backup.volid, "backup_id" => backup.id}
          })
        )
      end
    end)

    {:ok, length(stale)}
  end

  @doc "Forgets a backup the node has confirmed it deleted."
  def forget(backup_id) do
    case Repo.get(VpsBackup, backup_id) do
      nil -> {:ok, :already_gone}
      backup -> Repo.delete(backup)
    end
  end

  @doc """
  Rolls a VPS back to `backup_id`.

  Destructive and deliberately narrow: the archive must belong to this VPS, must
  have completed, and must still have a handle on a file. The VPS goes to
  `:restoring` for the duration, which blocks every other action on it —
  including a second restore, which would race the first over the same disk.

  What the customer loses is everything written since the backup was taken. The
  control plane does not take a safety copy first: that would double the time,
  can fail for space on the node, and with two archives kept it would push out
  the older restore point the customer might actually have wanted. Saying so
  plainly before the button is pressed is the honest guard, not a hidden one.
  """
  def restore(%Vps{} = vps, backup_id) do
    with %VpsBackup{} = backup <- Repo.get(VpsBackup, backup_id),
         :ok <- restorable(vps, backup) do
      Multi.new()
      |> Multi.run(:vps, fn repo, _ ->
        # FOR UPDATE, and re-check the status inside the lock: two restores
        # dispatched at once would otherwise both pass the check above and both
        # tell the node to overwrite the same disk.
        locked = repo.one!(from v in Vps, where: v.id == ^vps.id, lock: "FOR UPDATE")

        if locked.status in [:active, :stopped] do
          locked |> Vps.changeset(%{status: :restoring}) |> repo.update()
        else
          {:error, {:invalid_status, locked.status}}
        end
      end)
      |> Multi.insert(:command, fn %{vps: locked} ->
        Command.changeset(%Command{}, %{
          node_id: locked.node_id,
          vps_id: locked.id,
          kind: :restore_backup,
          status: :pending,
          payload: %{
            "vm_id" => locked.provider_vm_id,
            "volid" => backup.volid,
            # What to leave the guest as afterwards. A VPS that was running
            # before a restore should be running after it.
            "start_after" => vps.status == :active
          }
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{vps: restoring}} -> {:ok, restoring}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp restorable(%Vps{} = vps, %VpsBackup{} = backup) do
    cond do
      # Not found rather than forbidden: whether some other customer's backup
      # exists is none of this caller's business.
      backup.vps_id != vps.id -> {:error, :not_found}
      backup.status != :done -> {:error, :backup_not_restorable}
      is_nil(backup.volid) -> {:error, :backup_not_restorable}
      is_nil(vps.node_id) or is_nil(vps.provider_vm_id) -> {:error, :not_provisioned}
      vps.status not in [:active, :stopped] -> {:error, {:invalid_status, vps.status}}
      true -> :ok
    end
  end

  @doc "A VPS's restore points, newest first. Failures included — they are news."
  def list_for_vps(vps_id) do
    Repo.all(
      from b in VpsBackup,
        where: b.vps_id == ^vps_id,
        order_by: [desc: b.inserted_at],
        limit: 50
    )
  end

  # --- internals -------------------------------------------------------------

  defp due_vpses(now) do
    cutoff = DateTime.add(now, -interval_seconds(), :second)

    # A VPS with a backup started after the cutoff is not due; one with a backup
    # still :running is not due either, whenever it started, because a second
    # vzdump of the same guest would fight the first for the node's disk.
    recent =
      from b in VpsBackup,
        where:
          b.vps_id == parent_as(:vps).id and
            (b.started_at >= ^cutoff or b.status == :running),
        select: 1

    Repo.all(
      from v in Vps,
        as: :vps,
        join: n in assoc(v, :node),
        where:
          v.status == :active and not is_nil(v.provider_vm_id) and
            n.status in [:online, :draining],
        where: not exists(recent),
        preload: [:node]
    )
  end

  defp sane_size(n) when is_integer(n) and n >= 0, do: n

  defp sane_size(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp sane_size(_), do: nil
end
