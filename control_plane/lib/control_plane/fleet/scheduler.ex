defmodule ControlPlane.Fleet.Scheduler do
  @moduledoc """
  Capacity-aware placement of VPS requests onto fleet nodes.

  The scheduler selects an `:online` node in the requested region that has enough
  live available capacity for the request, picks the *least-loaded* fitting node
  (the one with the most headroom remaining after placement), then atomically
  decrements that node's available capacity and records a `:held`
  `ControlPlane.Fleet.Reservation`.

  To avoid overcommitting a node when two placement requests race, candidate rows
  are read with `SELECT ... FOR UPDATE` inside a transaction so concurrent
  schedulers serialize on the same node rows.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias ControlPlane.Repo
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.{Node, Reservation}

  @type request :: %{
          required(:region_id) => binary(),
          required(:vcpu) => non_neg_integer(),
          required(:ram_mb) => non_neg_integer(),
          required(:disk_gb) => non_neg_integer()
        }

  @doc """
  Places `request` onto the best-fitting online node in its region.

  `request` is a map with `:region_id`, `:vcpu`, `:ram_mb` and `:disk_gb`.

  Options:

    * `:vps_id` - associate the created reservation with this VPS.

  Returns `{:ok, %{node: node, reservation: reservation}}` on success or
  `{:error, :no_capacity}` when no node in the region can fit the request.
  """
  @spec place(request(), keyword()) ::
          {:ok, %{node: Node.t(), reservation: Reservation.t()}} | {:error, :no_capacity}
  def place(request, opts \\ []) do
    multi =
      Multi.new()
      # 1. Lock and load the fitting candidates in this region. Locking here means
      #    any concurrent placement targeting the same nodes blocks until we commit
      #    or roll back, preventing two requests from both reading stale capacity.
      |> Multi.run(:candidates, fn repo, _changes ->
        {:ok, lock_candidates(repo, request)}
      end)
      # 2. Pick the least-loaded fitting node (or fail with :no_capacity).
      |> Multi.run(:node, fn _repo, %{candidates: candidates} ->
        case pick_node(candidates, request) do
          nil -> {:error, :no_capacity}
          node -> {:ok, node}
        end
      end)
      # 3. Decrement the chosen node's available capacity.
      |> Multi.update(:decrement, fn %{node: node} ->
        decrement_changeset(node, request)
      end)
      # 4. Record the held reservation against that node.
      |> Multi.insert(:reservation, fn %{node: node} ->
        reservation_changeset(node, request, opts)
      end)

    case Repo.transaction(multi) do
      {:ok, %{decrement: node, reservation: reservation}} ->
        {:ok, %{node: node, reservation: reservation}}

      {:error, :node, :no_capacity, _changes} ->
        {:error, :no_capacity}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Load online nodes in the region that fit the request, locking the rows FOR
  # UPDATE so capacity decisions are serialized across concurrent schedulers.
  defp lock_candidates(repo, %{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb} = request) do
    Fleet.online_nodes_in_region_query(request.region_id)
    |> where(
      [n],
      n.available_vcpu >= ^vcpu and
        n.available_ram_mb >= ^ram_mb and
        n.available_disk_gb >= ^disk_gb
    )
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  # Choose the least-loaded fitting node: the one that retains the most headroom
  # after the request is subtracted. We score by the sum of the fractions of each
  # resource that would remain free, so a node that would be left most idle wins.
  defp pick_node([], _request), do: nil

  defp pick_node(candidates, request) do
    Enum.max_by(candidates, &headroom_score(&1, request))
  end

  # Fraction of each resource still free after placement, summed. Higher is more
  # idle / less loaded. Total capacities are guarded against nil/zero.
  defp headroom_score(%Node{} = node, request) do
    frac(node.available_vcpu - request.vcpu, node.total_vcpu) +
      frac(node.available_ram_mb - request.ram_mb, node.total_ram_mb) +
      frac(node.available_disk_gb - request.disk_gb, node.total_disk_gb)
  end

  defp frac(_remaining, total) when is_nil(total) or total <= 0, do: 0.0
  defp frac(remaining, total), do: remaining / total

  defp decrement_changeset(%Node{} = node, request) do
    Ecto.Changeset.change(node,
      available_vcpu: node.available_vcpu - request.vcpu,
      available_ram_mb: node.available_ram_mb - request.ram_mb,
      available_disk_gb: node.available_disk_gb - request.disk_gb
    )
  end

  defp reservation_changeset(%Node{} = node, request, opts) do
    Reservation.changeset(%Reservation{}, %{
      node_id: node.id,
      vps_id: Keyword.get(opts, :vps_id),
      vcpu: request.vcpu,
      ram_mb: request.ram_mb,
      disk_gb: request.disk_gb,
      status: :held
    })
  end
end
