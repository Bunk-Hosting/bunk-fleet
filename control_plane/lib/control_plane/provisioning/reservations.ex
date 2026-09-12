defmodule ControlPlane.Provisioning.Reservations do
  @moduledoc """
  The capacity a VPS holds on its node, and giving it back exactly once.

  A reservation is the fleet's accounting entry for "this machine has been
  promised these resources". It is `:held` from the moment the scheduler places a
  VPS, `:committed` once the guest exists, and `:released` when it is gone. The
  node's advertised free capacity is decremented at placement and restored on
  release — so releasing twice inflates what the fleet believes it has spare, and
  overselling follows.

  That is why every function here takes a `repo`: each caller is already inside a
  transaction that owns the outcome, and a release that is not part of the same
  transaction as the state change it accompanies is a release that can happen
  without it.
  """
  import Ecto.Query

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reservation

  @doc "The reservation a VPS holds before its guest exists, or nil."
  def held(repo, vps_id), do: in_status(repo, vps_id, :held)

  @doc "The reservation a VPS holds once its guest exists, or nil."
  def committed(repo, vps_id), do: in_status(repo, vps_id, :committed)

  @doc """
  Marks a reservation released. Tolerates `nil`, because every caller asks for a
  reservation that may already be gone — the reconciler reclaims orphans.
  """
  def release(_repo, nil), do: {:ok, nil}

  def release(repo, %Reservation{} = reservation),
    do: reservation |> Reservation.changeset(%{status: :released}) |> repo.update()

  @doc """
  Gives the node its capacity back, but only for a reservation this path actually
  released.

  Skipping `nil` is the whole point: restoring capacity the reconciler has
  already reclaimed would inflate the node's advertised free capacity, and the
  scheduler would then place onto resources that do not exist.
  """
  def restore_capacity(_repo, nil), do: {:ok, 0}

  def restore_capacity(repo, %Reservation{} = reservation),
    do: Node.add_capacity(repo, reservation)

  defp in_status(repo, vps_id, status) do
    repo.one(
      from r in Reservation,
        where: r.vps_id == ^vps_id and r.status == ^status,
        order_by: [asc: r.inserted_at],
        limit: 1
    )
  end
end
