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

  alias Ecto.Multi
  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Command, Node, Reservation, Vps}
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Scheduler

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
      # Tier comes from the persisted VPS (server-authoritative), so the scheduler
      # only ever sees a trusted value — a :datacenter VPS is never placed on a
      # community node (O-24).
      place_and_dispatch(vps, Map.put(req, :tier, vps.tier), attrs)
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
    Repo.transaction(fn ->
      # Serialize per owner so two concurrent creates can't both pass the quota
      # check and exceed the cap (TOCTOU). The lock is released at commit/rollback.
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [:erlang.phash2({:owner_vps, owner_id})])

      if count_live_vpses(owner_id) >= max_vpses_per_owner() do
        Repo.rollback(:quota_exceeded)
      else
        full =
          attrs
          |> Map.drop([:owner_id, "owner_id", :owner_email, "owner_email"])
          |> Map.put(:owner_id, owner_id)
          |> Map.put(:owner_email, email)

        case create_vps(full) do
          {:ok, %{vps: vps}} ->
            ControlPlane.Subscriptions.create_for_vps(vps, owner_id, attrs[:package_id] || attrs["package_id"])
            %{vps: vps}

          {:error, _op, reason, _changes} ->
            Repo.rollback(reason)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
    end)
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
        # `vpses_active_ip_uidx` unique index is the DB backstop, so two
        # concurrent creates on the same node can never share an address.
        multi =
          Multi.new()
          |> Multi.run(:allocation, fn repo, _changes -> allocate_ip(repo, attrs, node) end)
          |> Multi.run(:vps, fn repo, %{allocation: {_attrs, ip}} ->
            vps
            |> Vps.changeset(%{node_id: node.id, status: :provisioning, ip_address: ip})
            |> repo.update()
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
    if attrs[:ip_config] || attrs["ip_config"] do
      {:ok, {attrs, attrs[:ip_address] || attrs["ip_address"]}}
    else
      repo.query!("SELECT pg_advisory_xact_lock($1)", [:erlang.phash2({:vps_ip, node.id})])

      case ControlPlane.Fleet.IpPool.allocate(node) do
        {:ok, %{ip: ip, config: cfg}} ->
          {:ok, {attrs |> Map.put(:ip_config, cfg) |> Map.put(:ip_address, ip), ip}}

        {:error, reason} ->
          {:error, reason}
      end
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

      # Scheduled (capacity reserved) but provisioning never produced a live VM —
      # e.g. the node's agent died mid-provision. Release the held reservation,
      # restore the node's capacity and cancel any outstanding provision command,
      # then mark the VPS deleted so it can never get permanently stuck undeletable.
      %Vps{provider_vm_id: nil} = vps ->
        cancel_and_release(vps)

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
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      vps = repo.get!(Vps, vps_id)

      # Keep the IP the control plane allocated + injected via cloud-init. Only
      # take the agent-reported IP when it actually has one (e.g. DHCP); a nil/
      # empty report must NOT wipe the address we already assigned, or the VPS
      # becomes unreachable (no console, no SSH).
      ip = case result["ip"] do
        v when is_binary(v) and v != "" -> v
        _ -> vps.ip_address
      end

      vps
      |> Vps.changeset(%{
        status: :active,
        provider_vm_id: result["vm_id"],
        ip_address: ip
      })
      |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      case held_reservation(repo, vps_id) do
        nil ->
          Logger.warning("provision done for vps #{vps_id}: no held reservation to commit")
          {:ok, nil}

        reservation ->
          reservation |> Reservation.changeset(%{status: :committed}) |> repo.update()
      end
    end)
  end

  # Provision failed: mark the VPS failed and release its held reservation, adding
  # the freed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :provision, vps_id: vps_id}, :failed, _result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      vps = repo.get!(Vps, vps_id)

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
  end

  # Delete succeeded: the VM is gone, so mark the VPS :deleted, release its
  # committed reservation and add the reclaimed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :delete, vps_id: vps_id}, :done, _result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      vps = repo.get!(Vps, vps_id)

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
    Logger.error(
      "delete command failed for vps #{vps_id}: #{inspect(result["error"])}; " <>
        "VPS left intact for retry"
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
      vps = repo.get!(Vps, vps_id)

      if vps.status in [:active, :stopped, :paused] do
        vps |> Vps.changeset(%{status: target}) |> repo.update()
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

  # Non-provision/non-delete commands (or those without an associated VPS) only
  # update the command itself.
  defp finalize_vps(multi, _command, _outcome, _result), do: multi

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
  defp restore_if_present(repo, %Reservation{} = reservation), do: Node.add_capacity(repo, reservation)

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
      # Server-set only (this builder is internal): falls back to the schema default
      # :community. A package/SKU layer can request :datacenter; the public create
      # params never reach here, so a customer can't self-select a tier (O-24).
      tier: attrs[:tier] || attrs["tier"] || :community,
      status: :queued
    })
  end

  # The exact snake_case payload the Go agent expects for a provision command.
  defp provision_payload(%Vps{} = vps, attrs) do
    %{
      "name" => vps.name,
      "vcpu" => vps.vcpu,
      "ram_mb" => vps.ram_mb,
      "disk_gb" => vps.disk_gb,
      "template_id" => attrs[:template_id] || attrs["template_id"] || default_template_id(),
      "cloud_init" => attrs[:cloud_init] || attrs["cloud_init"] || %{},
      "ssh_keys" => (attrs[:ssh_keys] || attrs["ssh_keys"] || []) ++ console_public_keys(),
      "ip_config" => attrs[:ip_config] || attrs["ip_config"]
    }
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
