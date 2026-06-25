defmodule ControlPlane.Provisioning do
  @moduledoc """
  Drives the lifecycle of a VPS from request to running instance:

    1. `create_vps/1` records the VPS, asks the `ControlPlane.Fleet.Scheduler` to
       place it onto a node (holding capacity), and enqueues a `:provision`
       `ControlPlane.Fleet.Command` for that node's agent.
    2. The node's agent polls `pending_commands_for_node/1` (via the command API),
       which are marked delivered with `mark_delivered/1`.
    3. The agent reports the outcome through `apply_result/2`, which finalises both
       the command and the VPS, committing or releasing the held reservation.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Command, Node, Reservation, Vps}
  alias ControlPlane.Fleet.Scheduler

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

  defp place_and_dispatch(%Vps{} = vps, req, attrs) do
    case Scheduler.place(req, vps_id: vps.id) do
      {:ok, %{node: node}} ->
        multi =
          Multi.new()
          |> Multi.update(:vps, Vps.changeset(vps, %{node_id: node.id, status: :provisioning}))
          |> Multi.insert(:command, fn %{vps: vps} ->
            Command.changeset(%Command{}, %{
              node_id: node.id,
              vps_id: vps.id,
              kind: :provision,
              status: :pending,
              payload: provision_payload(vps, attrs)
            })
          end)

        case Repo.transaction(multi) do
          {:ok, %{vps: vps, command: command}} -> {:ok, %{vps: vps, command: command}}
          {:error, _step, reason, _changes} -> {:error, reason}
        end

      {:error, :no_capacity} ->
        {:ok, _failed} = mark_vps_failed(vps)
        {:error, :no_capacity}
    end
  end

  @doc """
  Lists the `:pending` commands awaiting delivery for `node`, oldest first.
  """
  def pending_commands_for_node(%Node{id: node_id}) do
    Repo.all(
      from c in Command,
        where: c.node_id == ^node_id and c.status == :pending,
        order_by: [asc: c.inserted_at]
    )
  end

  @doc """
  Marks a command as `:delivered` (it has been handed to the node's agent).
  """
  def mark_delivered(%Command{} = command) do
    command
    |> Command.changeset(%{status: :delivered})
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
      to the node.

  Returns `{:ok, command}` with the updated command.
  """
  def apply_result(%Command{} = command, %{"status" => status} = result) do
    outcome = if status == "done", do: :done, else: :failed

    multi =
      Multi.new()
      |> Multi.update(:command, Command.changeset(command, %{status: outcome, result: result}))
      |> finalize_vps(command, outcome, result)

    case Repo.transaction(multi) do
      {:ok, %{command: command}} -> {:ok, command}
      {:error, _step, reason, _changes} -> {:error, reason}
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

      vps
      |> Vps.changeset(%{
        status: :active,
        provider_vm_id: result["vm_id"],
        ip_address: result["ip"]
      })
      |> repo.update()
    end)
    |> Multi.update(:reservation, fn _changes ->
      reservation = held_reservation!(vps_id)
      Reservation.changeset(reservation, %{status: :committed})
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
      reservation = held_reservation!(vps_id)

      reservation
      |> Reservation.changeset(%{status: :released})
      |> repo.update()
    end)
    |> Multi.update(:restore_capacity, fn %{reservation: reservation} ->
      node = Repo.get!(Node, reservation.node_id)

      Ecto.Changeset.change(node,
        available_vcpu: node.available_vcpu + reservation.vcpu,
        available_ram_mb: node.available_ram_mb + reservation.ram_mb,
        available_disk_gb: node.available_disk_gb + reservation.disk_gb
      )
    end)
  end

  # Non-provision commands (or those without an associated VPS) only update the
  # command itself.
  defp finalize_vps(multi, _command, _outcome, _result), do: multi

  defp held_reservation!(vps_id) do
    Repo.one!(
      from r in Reservation,
        where: r.vps_id == ^vps_id and r.status == :held,
        limit: 1
    )
  end

  defp vps_changeset(attrs) do
    Vps.changeset(%Vps{}, %{
      name: attrs[:name] || attrs["name"],
      region_id: attrs[:region_id] || attrs["region_id"],
      vcpu: attrs[:vcpu] || attrs["vcpu"],
      ram_mb: attrs[:ram_mb] || attrs["ram_mb"],
      disk_gb: attrs[:disk_gb] || attrs["disk_gb"],
      owner_email: attrs[:owner_email] || attrs["owner_email"],
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
      "template_id" => attrs[:template_id] || attrs["template_id"],
      "cloud_init" => attrs[:cloud_init] || attrs["cloud_init"] || %{},
      "ssh_keys" => attrs[:ssh_keys] || attrs["ssh_keys"] || [],
      "ip_config" => attrs[:ip_config] || attrs["ip_config"]
    }
  end

  defp mark_vps_failed(%Vps{} = vps) do
    vps
    |> Vps.changeset(%{status: :failed})
    |> Repo.update()
  end
end
