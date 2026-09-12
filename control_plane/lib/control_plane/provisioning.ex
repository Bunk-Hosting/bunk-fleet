defmodule ControlPlane.Provisioning do
  @moduledoc """
  Drives the lifecycle of a VPS from request to running instance:

    1. `create_vps/1` records the VPS, asks the `ControlPlane.Fleet.Scheduler` to
       place it onto a node (holding capacity), and enqueues a `:provision`
       `ControlPlane.Fleet.Command` for that node's agent.
    2. The node's agent polls `deliverable_commands_for_node/1` (via the command
       API), each marked delivered with `mark_delivered/1`. A command lost to an
       agent crash (delivered but never resolved) is redelivered after a TTL.
    3. The agent reports the outcome through `apply_result/2`, which finalises both
       the command and the VPS, committing or releasing the held reservation.
  """
  import Ecto.Query, warn: false
  require Logger

  alias ControlPlane.Backups
  alias ControlPlane.Console.HostKeys
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.IpPool
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.PortPool
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Scheduler
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Locks
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions
  alias ControlPlane.Subscriptions.Subscription
  alias Ecto.Multi

  # How long a `:delivered` command may sit without a reported result before it
  # is considered lost (agent crashed mid-flight) and becomes eligible for
  # redelivery. Redelivery is safe only because the Go agent treats commands
  # idempotently (a re-issued provision/delete for an already-handled VM is a
  # no-op that re-reports the same result).
  @redelivery_ttl_seconds 90

  @doc """
  Creates a VPS and dispatches a provision command to the node it is placed on.

  This:

    * inserts the `Vps` in the `:queued` state (persisted up front so that even a
      placement failure leaves a durable, `:failed` record),
    * asks the scheduler to place it (which holds capacity on a node), and
    * on success, in one transaction, moves the VPS to `:provisioning`, pins it to
      the chosen node, and enqueues a `:provision` `Command` carrying the agent's
      snake_case payload.

  Returns `{:ok, %{vps: vps, command: command}}` on success. If no node can fit the
  request the VPS is marked `:failed` and `{:error, :no_capacity}` is returned.

  Recognised keys: `:region_id`, `:name`, `:vcpu`, `:ram_mb`, `:disk_gb`,
  `:owner_email`, `:template_id`, `:ssh_keys` (default `[]`), `:cloud_init`
  (default `%{}`), `:ip_config` (default `nil`).
  """
  def create_vps(attrs) do
    req = %{
      region_id: attrs[:region_id] || attrs["region_id"],
      vcpu: attrs[:vcpu] || attrs["vcpu"],
      ram_mb: attrs[:ram_mb] || attrs["ram_mb"],
      disk_gb: attrs[:disk_gb] || attrs["disk_gb"]
    }

    # Persist the VPS up front so that even a placement failure leaves a durable,
    # `:failed` record for the customer rather than rolling everything back.
    with {:ok, vps} <- Repo.insert(vps_changeset(attrs)) do
      place_and_dispatch(vps, req, attrs)
    end
  end

  @doc """
  Fails VPSes that were persisted but never dispatched, and says how many.

  `create_vps/1` inserts the row `:queued` and then places it. Between those two
  the control plane can stop — a deploy, a crash — and what is left is a row
  nobody will ever act on: no command, no reservation, no node, and a customer
  who has already been charged. It counts against their quota and shows in their
  dashboard as something about to happen, forever.

  Marking it `:failed` is the honest end state: the customer can see it went
  wrong and delete it, and it stops occupying a quota slot. It is deliberately
  not refunded here. The ledger records a charge against a user, not against a
  VPS, so a sweeper cannot tell which entry to reverse without guessing — and
  guessing with someone's money is worse than telling a person to look.
  """
  def fail_stuck_queued_vpses(grace_seconds \\ 600) do
    cutoff = DateTime.utc_now() |> DateTime.add(-grace_seconds, :second)

    stuck =
      Repo.all(
        from v in Vps,
          as: :vps,
          where: v.status == :queued and v.inserted_at < ^cutoff,
          # A row with a command is mid-dispatch, not abandoned.
          where: not exists(from c in Command, where: c.vps_id == parent_as(:vps).id, select: 1),
          select: v.id
      )

    Enum.each(stuck, fn vps_id ->
      Logger.error(
        "vps #{vps_id} was queued but never dispatched; failing it. " <>
          "The customer may have been charged — check the ledger."
      )
    end)

    {count, _} =
      Repo.update_all(
        from(v in Vps, where: v.id in ^stuck),
        set: [status: :failed, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    if count > 0, do: Events.broadcast_changed(:vps)
    count
  end

  @doc """
  Re-dispatches teardowns that failed, and returns how many it retried.

  A delete whose command fails leaves the VPS `:deleting` with a live VM still
  running on the node. It is recoverable — asking to delete again dispatches a
  fresh command — but the dashboard shows "being deleted" and offers no second
  button, so the nudge has to come from here.

  The spacing doubles with each failure: five minutes after the first, ten after
  the second, and so on to a ceiling. That is deliberate in both directions. A
  transient error — a busy storage, a node mid-reboot — clears on the next
  attempt; a real one (a VM the hypervisor will not release) stops generating a
  command every thirty seconds while still being retried hours later, when the
  node that was down for maintenance comes back.

  There is no give-up state on purpose. Marking the VPS `:failed` would let the
  customer clear it from their list while its VM kept running and its capacity
  stayed booked — tidy for them, a leak for the fleet.
  """
  def retry_stuck_deletes(grace_seconds \\ 300, max_backoff_seconds \\ 6 * 3600) do
    now = DateTime.utc_now()

    candidates =
      Repo.all(
        from v in Vps,
          as: :vps,
          where: v.status == :deleting and not is_nil(v.node_id),
          where:
            not exists(
              from c in Command,
                where:
                  c.vps_id == parent_as(:vps).id and c.kind == :delete and
                    c.status in [:pending, :delivered],
                select: 1
            )
      )

    candidates
    |> Enum.filter(&due_for_delete_retry?(&1, now, grace_seconds, max_backoff_seconds))
    |> Enum.map(fn vps ->
      Logger.error("retrying the failed teardown of vps #{vps.id}")
      dispatch_delete(vps)
    end)
    |> length()
  end

  defp due_for_delete_retry?(%Vps{} = vps, now, grace_seconds, max_backoff_seconds) do
    failures =
      Repo.all(
        from c in Command,
          where: c.vps_id == ^vps.id and c.kind == :delete and c.status == :failed,
          order_by: [desc: c.updated_at],
          select: c.updated_at
      )

    case failures do
      [] ->
        false

      [last | _] ->
        # 5 min, 10, 20, 40… so a genuinely broken teardown stops churning while
        # still being retried long after a node comes back.
        backoff =
          min(grace_seconds * Integer.pow(2, length(failures) - 1), max_backoff_seconds)

        DateTime.diff(now, last, :second) >= backoff
    end
  end

  @doc """
  Creates a VPS on behalf of an authenticated owner, enforcing the per-owner quota
  and stamping ownership from the trusted session (never the request body).

  Any `owner_id`/`owner_email` present in `attrs` is dropped and replaced with the
  caller's, so a user cannot provision a VPS into someone else's account. Returns
  `{:error, :quota_exceeded}` when the owner already holds the maximum number of
  live (non-`:deleted`/non-`:failed`) VPSes.
  """
  def create_vps_for_owner(%{id: owner_id, email: email}, attrs) do
    full =
      attrs
      |> Map.drop([:owner_id, "owner_id", :owner_email, "owner_email"])
      |> Map.put(:owner_id, owner_id)
      |> Map.put(:owner_email, email)

    # Placement + dispatch deliberately run AFTER the insert commits — each in its own
    # top-level transaction, never nested inside this one. Ecto uses no savepoint
    # for a nested transaction, so a normal placement failure (fleet full, IP
    # collision) inside the scheduler's `Repo.transaction` would otherwise poison
    # this enclosing transaction, and the following `mark_vps_failed`/reservation-
    # release update would raise "current transaction is aborted" → HTTP 500
    # instead of a clean {:error, :no_capacity} (→ 409).
    with {:ok, %Vps{} = vps} <- insert_within_quota(owner_id, full),
         {:ok, %{vps: placed}} <- place_and_dispatch(vps, placement_request(full), full) do
      start_subscription(placed, owner_id, full)
      {:ok, %{vps: placed}}
    end
  end

  # The quota gate and the durable :queued insert, in one short transaction: the
  # per-owner advisory lock (auto-released at commit) serialises concurrent
  # creates against the quota check, so two cannot both pass the cap.
  defp insert_within_quota(owner_id, attrs) do
    Repo.transaction(fn ->
      :ok = Locks.take(Repo, :owner_quota, owner_id)

      if count_live_vpses(owner_id) >= max_vpses_per_owner() do
        Repo.rollback(:quota_exceeded)
      else
        insert_or_rollback(attrs)
      end
    end)
  end

  defp insert_or_rollback(attrs) do
    case Repo.insert(vps_changeset(attrs)) do
      {:ok, vps} -> vps
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp placement_request(attrs) do
    %{
      region_id: attrs[:region_id] || attrs["region_id"],
      vcpu: attrs[:vcpu] || attrs["vcpu"],
      ram_mb: attrs[:ram_mb] || attrs["ram_mb"],
      disk_gb: attrs[:disk_gb] || attrs["disk_gb"]
    }
  end

  defp start_subscription(%Vps{} = vps, owner_id, attrs) do
    Subscriptions.create_for_vps(vps, owner_id, attrs[:package_id] || attrs["package_id"])
  end

  @doc """
  Counts an owner's live VPSes — everything except `:deleted`/`:failed`, which no
  longer occupy capacity and so don't count against quota.
  """
  def count_live_vpses(owner_id) do
    Repo.one(
      from v in Vps,
        where: v.owner_id == ^owner_id and v.status not in [:deleted, :failed],
        select: count(v.id)
    )
  end

  defp max_vpses_per_owner do
    Application.get_env(:control_plane, :max_vpses_per_owner, 10)
  end

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  # The in-browser console connects to each VPS over SSH with the platform console
  # key, so its public key is injected into every VPS via cloud-init (next to the
  # customer's own keys). Empty list when no console key is configured.
  defp console_public_keys do
    case (Application.get_env(:control_plane, :console) || [])[:ssh_public_key] do
      key when is_binary(key) and key != "" -> [key]
      _ -> []
    end
  end

  defp place_and_dispatch(%Vps{} = vps, req, attrs) do
    case Scheduler.place(req, vps_id: vps.id) do
      {:ok, %{node: node}} ->
        # IP allocation, the VPS update and the command insert run in ONE
        # transaction. Allocation takes a per-node advisory lock and the
        # `vpses_active_node_ip_uidx` unique index is the DB backstop, so two
        # concurrent creates on the same node can never share an address.
        multi =
          Multi.new()
          |> Multi.run(:allocation, fn repo, _changes -> allocate_ip(repo, attrs, node) end)
          |> Multi.run(:vps, fn repo, %{allocation: {_attrs, ip}} ->
            vps
            |> Vps.changeset(%{node_id: node.id, status: :provisioning, ip_address: ip})
            |> repo.update()
          end)
          # A customer needs somewhere to connect. The node's own address plus an
          # allocated port is it — in the same transaction as the IP, so a VPS
          # never exists having been promised an endpoint it did not get.
          |> Multi.run(:ssh_forward, fn repo, %{vps: vps} ->
            allocate_ssh_forward(repo, node, vps)
          end)
          |> Multi.insert(:command, fn %{vps: vps, allocation: {attrs, _ip}} ->
            Command.changeset(%Command{}, %{
              node_id: node.id,
              vps_id: vps.id,
              kind: :provision,
              status: :pending,
              payload: provision_payload(vps, attrs)
            })
          end)

        case Repo.transaction(multi) do
          {:ok, %{vps: vps, command: command}} ->
            Events.broadcast_changed(:vps)
            {:ok, %{vps: vps, command: command}}

          {:error, _step, reason, _changes} ->
            # Any failure here is AFTER the scheduler reserved capacity, so release
            # the held reservation and restore the node's capacity (else it leaks).
            {:ok, _} = fail_and_release_reservation(vps.id)
            Events.broadcast_changed(:vps)
            {:error, reason}
        end

      {:error, :no_capacity} ->
        {:ok, _failed} = mark_vps_failed(vps)
        # The VPS was persisted (now :failed) so the dashboard should still update.
        Events.broadcast_changed(:vps)
        {:error, :no_capacity}
    end
  end

  # Resolves the VPS IP inside the dispatch transaction. An explicit ip_config
  # (admin override) wins; otherwise a per-node advisory lock serialises pool
  # allocation so concurrent creates can't pick the same address.
  defp allocate_ip(repo, attrs, node) do
    cfg = attrs[:ip_config] || attrs["ip_config"]

    if cfg do
      # Derive ip_address from the explicit config (or a passed ip_address) so the
      # control plane's record IS the assigned address — the authoritative console
      # target — rather than leaving it nil and later trusting the agent's report.
      ip = attrs[:ip_address] || attrs["ip_address"] || ip_from_config(cfg)
      {:ok, {Map.put(attrs, :ip_address, ip), ip}}
    else
      :ok = Locks.take(repo, :node_allocation, node.id)

      case IpPool.allocate(node) do
        {:ok, %{ip: ip, config: cfg}} ->
          {:ok, {attrs |> Map.put(:ip_config, cfg) |> Map.put(:ip_address, ip), ip}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Every VPS gets an SSH forward at provision time rather than on request: it is
  # the one port nobody can do without, and a customer discovering after the fact
  # that they have to go and ask for SSH is a customer who bought the wrong thing.
  #
  # A node with no public address gets no forward and no error. That is not a
  # failure — it is a node nothing outside can reach yet, and the API says so
  # rather than inventing an endpoint.
  defp allocate_ssh_forward(_repo, %Node{public_host: nil}, _vps), do: {:ok, nil}

  defp allocate_ssh_forward(repo, %Node{} = node, %Vps{} = vps) do
    case PortPool.allocate(repo, node, %{vps_id: vps.id, target_port: 22, purpose: "ssh"}) do
      {:ok, forward} ->
        {:ok, forward}

      {:error, :port_pool_exhausted} = error ->
        error

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Marks a VPS :failed and releases its held reservation, returning the freed
  # capacity to the node (mirrors the agent-reported provision-failure path).
  defp fail_and_release_reservation(vps_id) do
    Multi.new()
    |> Multi.run(:vps, fn repo, _changes ->
      repo.get!(Vps, vps_id) |> Vps.changeset(%{status: :failed}) |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      release_reservation(repo, held_reservation(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      restore_if_present(repo, reservation)
    end)
    |> Repo.transaction()
  end

  @doc """
  Begins teardown of a VPS by dispatching a `:delete` command to its node.

  In one transaction this moves the VPS to `:deleting` and enqueues a `:delete`
  `Command` carrying the provider VM id for the node's agent to destroy. The
  reservation is only released later, once the agent reports the delete `done`
  (see `apply_result/2`), so capacity is not freed before the VM is actually gone.

  Returns `{:ok, %{vps: vps, command: command}}`, or `{:error, :not_found}` if no
  VPS with `vps_id` exists, or `{:error, :no_node}` if the VPS was never placed
  on a node / provisioned (no `node_id` or `provider_vm_id`) and so has nothing
  for an agent to delete.
  """
  def delete_vps(vps_id) do
    # Deleting a VPS ends its subscription — do it up front so recurring billing
    # stops immediately, even while an async teardown is still in flight.
    # Idempotent: a no-op if it's already cancelled or the VPS doesn't exist.
    _ = Subscriptions.cancel_for_vps(vps_id)

    case Repo.get(Vps, vps_id) do
      nil ->
        {:error, :not_found}

      %Vps{status: :deleted} ->
        {:error, :already_deleting}

      # Already :deleting: only block if a delete command is still in flight. If a
      # previous delete terminally failed (e.g. a transient Proxmox error), allow
      # a fresh attempt so a VPS can never get permanently stuck undeletable.
      %Vps{status: :deleting} = vps ->
        if delete_in_flight?(vps.id),
          do: {:error, :already_deleting},
          else: dispatch_delete(vps)

      # A :failed VPS has no live VM and no held reservation (the reservation, if
      # any, was already released when provisioning failed), so it can be cleaned
      # up directly — no agent round-trip needed.
      %Vps{status: :failed} = vps ->
        mark_vps_deleted(vps)

      # Not yet scheduled to a node — no VM and no held reservation, so it can be
      # cleaned up directly. Lets a customer cancel a VPS still waiting for capacity.
      %Vps{node_id: nil} = vps ->
        mark_vps_deleted(vps)

      # Scheduled (capacity reserved) but no live VM recorded yet. If the provision
      # command is still in flight (delivered to the agent), the agent may be
      # mid-CreateVM; force-failing it now would orphan the VM it produces AND
      # double-count the freed capacity. Defer: mark :deleting and let the
      # provision-done result run the compensating teardown. Only when nothing is
      # in flight is it safe to cancel-and-release immediately.
      %Vps{provider_vm_id: nil} = vps ->
        if provision_in_flight?(vps.id),
          do: defer_teardown(vps),
          else: cancel_and_release(vps)

      %Vps{} = vps ->
        dispatch_delete(vps)
    end
  end

  # True if a delete command for this VPS is still pending/delivered (in flight).
  defp power_in_flight?(vps_id, kind) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == ^kind and c.status in [:pending, :delivered]
    )
  end

  defp delete_in_flight?(vps_id) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == :delete and c.status in [:pending, :delivered]
    )
  end

  # A provision command already handed to the agent (:delivered). Distinct from a
  # merely :pending one, which the agent has not started — that one is safe to
  # cancel outright.
  defp provision_in_flight?(vps_id) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == :provision and c.status == :delivered
    )
  end

  # Record delete intent without failing the in-flight provision or releasing
  # capacity. The provision result (see finalize_vps/4, :provision/:done) then
  # dispatches a compensating :delete for whatever VM the agent created and frees
  # capacity only once that delete confirms — so nothing is orphaned or
  # double-counted.
  defp defer_teardown(%Vps{} = vps) do
    case vps |> Vps.changeset(%{status: :deleting}) |> Repo.update() do
      {:ok, vps} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Moves the VPS to :deleting and enqueues a :delete command for its node's agent.
  defp dispatch_delete(%Vps{} = vps) do
    multi =
      Multi.new()
      |> Multi.update(:vps, Vps.changeset(vps, %{status: :deleting}))
      |> Multi.insert(:command, fn %{vps: vps} ->
        Command.changeset(%Command{}, %{
          node_id: vps.node_id,
          vps_id: vps.id,
          kind: :delete,
          status: :pending,
          payload: %{"vm_id" => vps.provider_vm_id}
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{vps: vps, command: command}} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: command}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Dispatches a power command (`:start`/`:stop`/`:pause`/`:resume`) to a VPS's node.

  Guards on the VPS's current status so only valid transitions are issued: start
  from `:stopped`; stop from `:active`/`:paused`; pause from `:active`; resume from
  `:paused`. The VPS must be placed and provisioned (`node_id` + `provider_vm_id`).
  The status only changes once the agent reports the command done (see
  `apply_result/2`), so the dashboard reflects the real hypervisor state.

  Returns `{:ok, %{vps: vps, command: command}}`, or `{:error, reason}` where reason
  is `:not_found`, `:not_provisioned`, or `{:invalid_status, status}`.
  """
  def start_vps(vps_id), do: dispatch_power(vps_id, :start, [:stopped])
  def stop_vps(vps_id), do: dispatch_power(vps_id, :stop, [:active, :paused])
  def pause_vps(vps_id), do: dispatch_power(vps_id, :pause, [:active])
  def resume_vps(vps_id), do: dispatch_power(vps_id, :resume, [:paused])

  defp dispatch_power(vps_id, kind, allowed) do
    case Repo.get(Vps, vps_id) do
      nil ->
        {:error, :not_found}

      %Vps{node_id: nil} ->
        {:error, :not_provisioned}

      %Vps{provider_vm_id: nil} ->
        {:error, :not_provisioned}

      %Vps{status: status} = vps ->
        cond do
          status not in allowed ->
            {:error, {:invalid_status, status}}

          # R5: an identical power command is already queued/delivered (e.g. a
          # double-clicked Stop) — don't enqueue a duplicate. Idempotent no-op.
          power_in_flight?(vps_id, kind) ->
            {:ok, %{vps: vps, command: nil}}

          true ->
            multi =
              Multi.insert(Multi.new(), :command, fn _ ->
                Command.changeset(%Command{}, %{
                  node_id: vps.node_id,
                  vps_id: vps.id,
                  kind: kind,
                  status: :pending,
                  payload: %{"vm_id" => vps.provider_vm_id}
                })
              end)

            case Repo.transaction(multi) do
              {:ok, %{command: command}} ->
                Events.broadcast_changed(:vps)
                {:ok, %{vps: vps, command: command}}

              {:error, _step, reason, _changes} ->
                {:error, reason}
            end
        end
    end
  end

  @doc """
  Lists the commands that should be (re)delivered to `node` now, oldest first.

  A command is deliverable when it is either:

    * still `:pending` (never handed out), or
    * `:delivered` but stale — its `delivered_at` is older than the redelivery
      TTL (#{@redelivery_ttl_seconds}s), meaning the agent likely crashed before
      reporting a result.

  Terminal commands (`:done` / `:failed`) are never returned. Redelivery relies
  on the agent being idempotent (handled on the Go side): re-issuing a
  provision/delete for an already-processed VM must be a safe no-op that
  re-reports the original outcome.
  """
  def deliverable_commands_for_node(%Node{id: node_id}) do
    cutoff = DateTime.add(now(), -@redelivery_ttl_seconds, :second)

    Repo.all(
      from c in Command,
        where:
          c.node_id == ^node_id and
            (c.status == :pending or
               (c.status == :delivered and not is_nil(c.delivered_at) and
                  c.delivered_at < ^cutoff)),
        order_by: [asc: c.inserted_at]
    )
  end

  @doc """
  Marks a command as `:delivered`, stamping `delivered_at` with the current time.

  Re-delivering an already-`:delivered` command simply refreshes `delivered_at`,
  resetting its redelivery window.
  """
  def mark_delivered(%Command{} = command) do
    command
    |> Command.changeset(%{status: :delivered, delivered_at: now()})
    |> Repo.update()
  end

  @doc """
  Marks a whole batch of commands `:delivered` in a single UPDATE. Same effect as
  calling `mark_delivered/1` per command (including resetting `delivered_at` for a
  redelivery) but without the N+1. Returns `{count, nil}`.
  """
  def mark_delivered_all([]), do: {0, nil}

  def mark_delivered_all(commands) do
    ids = Enum.map(commands, & &1.id)
    ts = now()

    # Guard on non-terminal status: a concurrent apply_result / cancel_and_release
    # may have moved a command to :done/:failed between the poll's read and this
    # write. Without the guard we'd resurrect a cancelled command back to
    # :delivered and hand the agent a provision/delete it must not run (orphan VM,
    # double-booked capacity).
    Repo.update_all(
      from(c in Command, where: c.id in ^ids and c.status in [:pending, :delivered]),
      set: [status: :delivered, delivered_at: ts, updated_at: ts]
    )
  end

  @doc """
  Applies a result reported by a node's agent for `command`.

  The `result` map uses string keys: `"status"` (`"done"` or `"failed"`),
  `"vm_id"`, `"ip"` and `"error"`.

  In a single transaction:

    * the command is moved to `:done` / `:failed` and the raw `result` is stored, and
    * for a provision command, the VPS is moved to `:active` (recording `vm_id`/`ip`)
      and its held reservation `:committed` on success; on failure the VPS is moved
      to `:failed` and its held reservation `:released`, returning the freed capacity
      to the node, and
    * for a delete command, on success the VPS is moved to `:deleted` and its
      committed reservation `:released`, returning capacity to the node; on failure
      the VPS and reservation are left untouched (the VM may still exist) and the
      error is recorded on the command and logged for retry.

  This is IDEMPOTENT: results may be re-delivered or retried (see
  `deliverable_commands_for_node/1`). The command row is locked `FOR UPDATE` and
  re-read; if it is already terminal (`:done`/`:failed`) the call is a no-op, so a
  duplicate result can never release a reservation or restore node capacity twice.
  The lock also serializes concurrent applications of the same command.

  Returns `{:ok, command}` with the (already- or newly-)applied command.
  """
  def apply_result(%Command{} = command, %{"status" => status} = result) do
    outcome = if status == "done", do: :done, else: :failed

    multi =
      Multi.new()
      # Lock + re-read the command. Abort (idempotent no-op) if it's already
      # terminal; this serializes concurrent/duplicate result deliveries.
      |> Multi.run(:lock, fn repo, _changes ->
        locked = repo.one!(from c in Command, where: c.id == ^command.id, lock: "FOR UPDATE")

        if locked.status in [:done, :failed],
          do: {:error, :already_applied},
          else: {:ok, locked}
      end)
      |> Multi.update(:command, fn %{lock: locked} ->
        Command.changeset(locked, %{status: outcome, result: result})
      end)
      |> finalize_vps(command, outcome, result)

    case Repo.transaction(multi) do
      {:ok, %{command: command}} ->
        Events.broadcast_changed(:vps)
        {:ok, command}

      # The result was already applied by a prior (or concurrent) delivery.
      {:error, :lock, :already_applied, _changes} ->
        {:ok, command}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # --- internal helpers -----------------------------------------------------

  # Provision succeeded: activate the VPS (recording provider id / ip) and commit
  # the held reservation. Capacity stays decremented.
  defp finalize_vps(multi, %Command{kind: :provision, vps_id: vps_id}, :done, result)
       when not is_nil(vps_id) do
    vm_id = sane_vm_id(result["vm_id"])

    multi
    |> Multi.run(:vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      cond do
        # A delete was requested while this provision was in flight (deferred
        # teardown): the VM now exists, so record its id and stay :deleting — the
        # compensating :delete below tears it down. Never activate a VPS the
        # customer already deleted.
        vps.status in [:deleting, :deleted] and is_binary(vm_id) ->
          vps |> Vps.changeset(%{provider_vm_id: vm_id}) |> repo.update()

        # Delete requested but the provision produced no usable VM id → nothing to
        # tear down, so finish the delete now.
        vps.status in [:deleting, :deleted] ->
          vps |> Vps.changeset(%{status: :deleted}) |> repo.update()

        # Normal path: activate. The browser console SSHes to exactly
        # vps.ip_address, so this MUST stay the CP-allocated address (see
        # console_ip/3) — never one the untrusted agent reports.
        true ->
          ip = console_ip(result["ip"], vps, repo)

          vps
          |> Vps.changeset(%{status: :active, provider_vm_id: vm_id, ip_address: ip})
          |> repo.update()
      end
    end)
    |> Multi.run(:reservation, fn repo, %{vps: vps} ->
      case held_reservation(repo, vps_id) do
        nil ->
          if vps.status not in [:deleted],
            do: Logger.warning("provision done for vps #{vps_id}: no held reservation to commit")

          {:ok, nil}

        held ->
          if vps.status == :deleted do
            # No VM was created and the customer deleted it → free capacity now.
            with {:ok, _} <- release_reservation(repo, held), do: restore_if_present(repo, held)
          else
            # Active, or :deleting-with-a-VM: commit the booking. For the latter the
            # committed reservation is what the delete-done path releases, so
            # capacity is freed exactly once — on confirmed teardown.
            held |> Reservation.changeset(%{status: :committed}) |> repo.update()
          end
      end
    end)
    |> Multi.run(:compensate, fn repo, %{vps: vps} ->
      if vps.status in [:deleting] and is_binary(vm_id) do
        %Command{}
        |> Command.changeset(%{
          node_id: vps.node_id,
          vps_id: vps_id,
          kind: :delete,
          status: :pending,
          payload: %{"vm_id" => vm_id}
        })
        |> repo.insert()
      else
        {:ok, nil}
      end
    end)
  end

  # Provision failed: mark the VPS failed and release its held reservation, adding
  # the freed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :provision, vps_id: vps_id}, :failed, result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      vps
      |> Vps.changeset(%{status: :failed})
      |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      release_reservation(repo, held_reservation(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      restore_if_present(repo, reservation)
    end)
    # A provision the customer already paid for at create just died. Refund the
    # subscription's monthly price and cancel it so recurring billing never charges
    # for a VM that never existed. Idempotent: refund/cancel run once, since the
    # subscription is only :cancelled here.
    |> Multi.run(:refund, fn repo, _changes -> refund_failed_provision(repo, vps_id) end)
    # A failed provision may have left a half-created VM on the operator's node
    # (the agent returns its id precisely so we can reconcile it). Enqueue a
    # compensating :delete so the orphan is destroyed rather than lingering and
    # silently consuming the operator's real capacity forever.
    |> maybe_cleanup_orphan(vps_id, sane_vm_id(result["vm_id"]))
  end

  # Delete succeeded: the VM is gone, so mark the VPS :deleted, release its
  # committed reservation and add the reclaimed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :delete, vps_id: vps_id}, :done, _result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      vps
      |> Vps.changeset(%{status: :deleted})
      |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      release_reservation(repo, committed_reservation(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      restore_if_present(repo, reservation)
    end)
  end

  # Delete failed: do NOT touch the VPS or its reservation — the VM may still
  # exist, so freeing capacity would risk a double-booking. We only record the
  # error on the command (done by the caller) and log for an operator to retry.
  defp finalize_vps(multi, %Command{kind: :delete, vps_id: vps_id}, :failed, result)
       when not is_nil(vps_id) do
    # Left :deleting with its VM still there — which is the truth, and which the
    # reconciler now acts on: retry_stuck_deletes/2 re-dispatches on a widening
    # interval rather than leaving the row to sit there hoping someone clicks
    # delete a second time.
    Logger.error(
      "delete command failed for vps #{vps_id}: #{inspect(result["error"])}; " <>
        "the teardown will be retried"
    )

    multi
  end

  # Power command succeeded: transition the VPS to the resulting power state.
  # Only a live VPS is transitioned (a delete that raced in must never be
  # resurrected); capacity is untouched because power state != capacity.
  defp finalize_vps(multi, %Command{kind: kind, vps_id: vps_id}, :done, _result)
       when kind in [:start, :stop, :pause, :resume] and not is_nil(vps_id) do
    target =
      case kind do
        :start -> :active
        :resume -> :active
        :stop -> :stopped
        :pause -> :paused
      end

    Multi.run(multi, :vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      if vps.status in [:active, :stopped, :paused] do
        changeset = Vps.changeset(vps, %{status: target})

        # Resuming into :active: reset the meter watermark to now so the interval
        # the VPS spent stopped/paused is NEVER billed. The meter only runs on
        # :active VPSes and computes `now - last_metered_at`; without this reset,
        # the first tick after resume would span the entire downtime, over-charging
        # the customer and over-paying the operator for time the VM never served.
        changeset =
          if target == :active do
            now = DateTime.truncate(DateTime.utc_now(), :second)
            Ecto.Changeset.put_change(changeset, :last_metered_at, now)
          else
            changeset
          end

        repo.update(changeset)
      else
        {:ok, vps}
      end
    end)
  end

  # Power command failed: leave the VPS as-is; the error is recorded on the
  # command by the caller. Log for visibility.
  defp finalize_vps(multi, %Command{kind: kind, vps_id: vps_id}, :failed, result)
       when kind in [:start, :stop, :pause, :resume] and not is_nil(vps_id) do
    Logger.error("#{kind} command failed for vps #{vps_id}: #{inspect(result["error"])}")
    multi
  end

  # A backup acts on archives beside the VPS, never on the VPS itself, so it
  # finalises into `vps_backups` and leaves the machine's status alone — a failed
  # backup must not make a running VPS look broken.
  defp finalize_vps(multi, %Command{kind: :backup, payload: payload}, _outcome, result) do
    case payload["backup_id"] do
      id when is_binary(id) ->
        Multi.run(multi, :backup, fn _repo, _changes ->
          Backups.record_result(id, result)
        end)

      _ ->
        multi
    end
  end

  defp finalize_vps(multi, %Command{kind: :delete_backup, payload: payload}, :done, _result) do
    case payload["backup_id"] do
      id when is_binary(id) ->
        Multi.run(multi, :backup, fn _repo, _changes ->
          Backups.forget(id)
        end)

      _ ->
        multi
    end
  end

  defp finalize_vps(multi, %Command{kind: :delete_backup, payload: payload}, :failed, result) do
    # The archive is still there and still taking up the node's disk. Keep the
    # row: it is the only handle on a file that now needs a person.
    Logger.error(
      "backup deletion failed for #{inspect(payload["volid"])}: #{inspect(result["error"])}"
    )

    multi
  end

  # A restore overwrote the guest's disk. Put the VPS back into the state the
  # customer had it in — running if it was running — and out of :restoring, which
  # has been blocking everything else on this machine.
  defp finalize_vps(multi, %Command{kind: :restore_backup, vps_id: vps_id, payload: p}, :done, _r)
       when not is_nil(vps_id) do
    target = if p["start_after"], do: :active, else: :stopped

    Multi.run(multi, :vps, fn repo, _changes ->
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      if vps.status == :restoring do
        # Reset the meter watermark: the VPS was not serving anyone while its
        # disk was being overwritten, and metering charges `now - last_metered_at`.
        attrs = %{status: target}
        changeset = Vps.changeset(vps, attrs)

        changeset =
          if target == :active,
            do:
              Ecto.Changeset.put_change(
                changeset,
                :last_metered_at,
                DateTime.utc_now() |> DateTime.truncate(:second)
              ),
            else: changeset

        # The disk is older, so the guest's SSH host key is older too. TOFU would
        # read that as exactly the attack it exists to catch and refuse the
        # console — locking the customer out of the thing they would use to check
        # the restore worked. Forget the pin; the next connection pins afresh.
        HostKeys.forget(vps.id)

        repo.update(changeset)
      else
        # Something else moved it — a delete that raced the restore. Leave it be.
        {:ok, vps}
      end
    end)
  end

  defp finalize_vps(multi, %Command{kind: :restore_backup, vps_id: vps_id}, :failed, result)
       when not is_nil(vps_id) do
    Logger.error("restore failed for vps #{vps_id}: #{inspect(result["error"])}")

    # Out of :restoring either way: leaving it there would block the customer
    # from touching their own machine forever over a failure that already
    # happened. :stopped, not :active — after a failed qmrestore the disk may be
    # half-written, and starting it automatically is the wrong default.
    Multi.run(multi, :vps, fn repo, _changes ->
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      if vps.status == :restoring,
        do: vps |> Vps.changeset(%{status: :stopped}) |> repo.update(),
        else: {:ok, vps}
    end)
  end

  # Non-provision/non-delete commands (or those without an associated VPS) only
  # update the command itself.
  defp finalize_vps(multi, _command, _outcome, _result), do: multi

  defp maybe_cleanup_orphan(multi, _vps_id, nil), do: multi

  defp maybe_cleanup_orphan(multi, vps_id, vm_id) do
    Multi.insert(multi, :orphan_cleanup, fn %{vps: vps} ->
      Command.changeset(%Command{}, %{
        node_id: vps.node_id,
        vps_id: vps_id,
        kind: :delete,
        status: :pending,
        payload: %{"vm_id" => vm_id}
      })
    end)
  end

  # Resolve the console target IP for a provision-done result.
  #
  # The control plane allocates the VPS IP itself (IpPool) and injects it via
  # cloud-init, so vps.ip_address is authoritative and we keep it — a differing
  # agent report is logged (possible operator misconfig or an attempt to redirect
  # the shared-key console at a co-tenant) but NOT applied.
  defp console_ip(reported, %Vps{ip_address: allocated} = vps, _repo)
       when is_binary(allocated) and allocated != "" do
    if is_binary(reported) and reported != "" and reported != allocated do
      Logger.warning(
        "vps #{vps.id}: agent-reported ip #{inspect(reported)} differs from CP-allocated #{allocated}; keeping allocated (console binds to the CP-assigned address)"
      )
    end

    allocated
  end

  # No CP-allocated IP (e.g. the node advertises no pool): only adopt the reported
  # IP if it is a valid IPv4 that falls inside the node's DECLARED range. Unlike
  # before there is NO accept-anything fallback — an unbounded node yields no IP
  # rather than trusting an arbitrary operator-supplied address.
  defp console_ip(reported, %Vps{} = vps, repo) when is_binary(reported) and reported != "" do
    node = vps.node_id && repo.get(Node, vps.node_id)

    if ControlPlane.Net.valid?(reported) and ip_in_declared_range?(reported, node) do
      reported
    else
      Logger.warning(
        "vps #{vps.id}: no CP-allocated ip and reported #{inspect(reported)} is not inside a declared node range; leaving ip unset"
      )

      nil
    end
  end

  defp console_ip(_reported, %Vps{ip_address: allocated}, _repo), do: allocated

  # Strict range check: a node WITHOUT a valid declared [start,end] range accepts
  # nothing (returns false), closing the old accept-any hole.
  defp ip_in_declared_range?(ip, %Node{vps_range_start: s, vps_range_end: e})
       when is_binary(s) and is_binary(e) do
    ControlPlane.Net.valid?(s) and ControlPlane.Net.valid?(e) and ControlPlane.Net.valid?(ip) and
      ControlPlane.Net.to_int(ip) >= ControlPlane.Net.to_int(s) and
      ControlPlane.Net.to_int(ip) <= ControlPlane.Net.to_int(e)
  end

  defp ip_in_declared_range?(_ip, _node), do: false

  # Pull the IPv4 out of a Proxmox-style ip_config ("ip=10.0.0.5/24,gw=..."), so
  # an explicit-config VPS still gets an authoritative ip_address.
  defp ip_from_config(cfg) when is_binary(cfg) do
    case Regex.run(~r/\bip=(\d+\.\d+\.\d+\.\d+)/, cfg) do
      [_, ip] -> if ControlPlane.Net.valid?(ip), do: ip, else: nil
      _ -> nil
    end
  end

  defp ip_from_config(_), do: nil

  # Bound the agent-supplied VM id to a sane length/charset so it can't smuggle
  # control characters or absurd values into the DB / later command payloads.
  defp sane_vm_id(v) when is_binary(v) do
    if v != "" and String.length(v) <= 64 and String.match?(v, ~r/\A[A-Za-z0-9._:-]+\z/),
      do: v,
      else: nil
  end

  defp sane_vm_id(_), do: nil

  defp refund_failed_provision(repo, vps_id) do
    case repo.one(
           from s in Subscription,
             where: s.vps_id == ^vps_id and s.status != :cancelled
         ) do
      nil ->
        {:ok, :no_subscription}

      sub ->
        cents = ControlPlane.Money.to_cents(sub.price_monthly)

        {:ok, _} =
          ControlPlane.Credits.refund(
            sub.owner_id,
            cents,
            "vps_refund",
            "Terugbetaling: provisioning mislukt"
          )

        {:ok, _} = Subscriptions.cancel_for_vps(vps_id)
        {:ok, :refunded}
    end
  end

  # Reservation lookups are intentionally non-bang (Repo.one, not Repo.one!).
  # A finalisation can legitimately find no matching reservation — the reconciler
  # may have already reclaimed a stale `:held` one, or a prior delivery already
  # released it. Raising here would fail the whole `apply_result/2` transaction,
  # the command would never reach a terminal state, and the agent would redeliver
  # the result forever. Returning nil lets the caller skip the release/restore and
  # still mark the command done. Run inside the locked txn via the passed `repo`.
  defp held_reservation(repo, vps_id), do: reservation_in(repo, vps_id, :held)
  defp committed_reservation(repo, vps_id), do: reservation_in(repo, vps_id, :committed)

  defp reservation_in(repo, vps_id, status) do
    repo.one(
      from r in Reservation,
        where: r.vps_id == ^vps_id and r.status == ^status,
        order_by: [asc: r.inserted_at],
        limit: 1
    )
  end

  # Releases a reservation if one was found, tolerating nil.
  defp release_reservation(_repo, nil), do: {:ok, nil}

  defp release_reservation(repo, %Reservation{} = reservation),
    do: reservation |> Reservation.changeset(%{status: :released}) |> repo.update()

  # Adds capacity back ONLY when this path released a reservation. Skipping a nil
  # avoids double-restoring capacity the reconciler already reclaimed (which would
  # inflate the node's advertised free capacity).
  defp restore_if_present(_repo, nil), do: {:ok, 0}

  defp restore_if_present(repo, %Reservation{} = reservation),
    do: Node.add_capacity(repo, reservation)

  defp vps_changeset(attrs) do
    Vps.changeset(%Vps{}, %{
      name: attrs[:name] || attrs["name"],
      region_id: attrs[:region_id] || attrs["region_id"],
      vcpu: attrs[:vcpu] || attrs["vcpu"],
      ram_mb: attrs[:ram_mb] || attrs["ram_mb"],
      disk_gb: attrs[:disk_gb] || attrs["disk_gb"],
      owner_email: attrs[:owner_email] || attrs["owner_email"],
      owner_id: attrs[:owner_id] || attrs["owner_id"],
      ip_address: attrs[:ip_address] || attrs["ip_address"],
      status: :queued
    })
  end

  # The exact snake_case payload the Go agent expects for a provision command.
  defp provision_payload(%Vps{} = vps, attrs) do
    %{
      "name" => guest_name(vps),
      "vcpu" => vps.vcpu,
      "ram_mb" => vps.ram_mb,
      "disk_gb" => vps.disk_gb,
      "template_id" => attrs[:template_id] || attrs["template_id"] || default_template_id(),
      "cloud_init" => attrs[:cloud_init] || attrs["cloud_init"] || %{},
      "ssh_keys" => (attrs[:ssh_keys] || attrs["ssh_keys"] || []) ++ console_public_keys(),
      "ip_config" => attrs[:ip_config] || attrs["ip_config"]
    }
  end

  # The hypervisor guest name the agent creates AND keys idempotency on
  # (FindByName). It MUST be globally unique per VPS: the customer-chosen display
  # name is not (two tenants can both name a VPS "web1" on the same node, and the
  # agent would then adopt the first tenant's live VM for the second — cross-tenant
  # takeover). We derive a DNS-safe slug of the display name plus a short slice of
  # the VPS's UUID, so the name stays readable but is unique and deterministic
  # across command re-deliveries.
  defp guest_name(%Vps{id: id, name: name}) do
    slug =
      (name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    slug = if slug == "", do: "vps", else: slug
    short = id |> String.replace("-", "") |> String.slice(0, 8)
    "#{slug}-#{short}"
  end

  defp mark_vps_failed(%Vps{} = vps) do
    vps
    |> Vps.changeset(%{status: :failed})
    |> Repo.update()
  end

  # Directly marks a VPS :deleted (no agent command), used to clean up a :failed
  # VPS. Mirrors the success shape of `delete_vps/1` (`command: nil`, no command
  # was issued) so callers can treat both uniformly.
  # Releases a still-held reservation for a VPS that never reached a live VM,
  # restores the node's advertised capacity, cancels any outstanding provision
  # command and marks the VPS deleted — all atomically.
  defp cancel_and_release(%Vps{} = vps) do
    Multi.new()
    |> Multi.run(:vps, fn repo, _changes ->
      repo.get!(Vps, vps.id) |> Vps.changeset(%{status: :deleted}) |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      release_reservation(repo, held_reservation(repo, vps.id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      restore_if_present(repo, reservation)
    end)
    |> Multi.update_all(
      :cancel_commands,
      from(c in Command,
        where:
          c.vps_id == ^vps.id and c.kind == :provision and
            c.status in [:pending, :delivered]
      ),
      set: [status: :failed]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{vps: vps}} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp mark_vps_deleted(%Vps{} = vps) do
    case vps |> Vps.changeset(%{status: :deleted}) |> Repo.update() do
      {:ok, vps} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
