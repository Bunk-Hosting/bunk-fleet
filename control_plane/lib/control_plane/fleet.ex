defmodule ControlPlane.Fleet do
  @moduledoc """
  The Fleet context: regions, nodes, VPSes and capacity reservations that make up
  the federated VPS control plane.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Node, Region}

  # A node is considered "online" for scheduling purposes only if it has reported
  # a heartbeat within this window.
  @heartbeat_ttl_seconds 120

  @doc """
  Returns all regions.
  """
  def list_regions do
    Repo.all(Region)
  end

  @doc """
  Registers (enrolls) a new node in the fleet.
  """
  def register_node(attrs) do
    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Records a heartbeat for the given node, refreshing its live available capacity,
  heartbeat timestamp and status.

  The caller's `attrs` are merged with a freshly stamped `last_heartbeat_at` (unless
  one was explicitly supplied).
  """
  def record_heartbeat(%Node{} = node, attrs) do
    attrs = Map.put_new(normalize_keys(attrs), :last_heartbeat_at, now())

    node
    |> Node.heartbeat_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists nodes in the given region that are currently `:online` and have reported a
  recent heartbeat.
  """
  def list_online_nodes_in_region(region_id) do
    Repo.all(online_nodes_in_region_query(region_id))
  end

  @doc """
  Query (not executed) selecting `:online` nodes in `region_id` with a recent
  heartbeat. Shared with the scheduler so locking variants can build on top of it.
  """
  def online_nodes_in_region_query(region_id) do
    cutoff = DateTime.add(now(), -@heartbeat_ttl_seconds, :second)

    from n in Node,
      where:
        n.region_id == ^region_id and
          n.status == :online and
          not is_nil(n.last_heartbeat_at) and
          n.last_heartbeat_at >= ^cutoff
  end

  @doc false
  def heartbeat_ttl_seconds, do: @heartbeat_ttl_seconds

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Allow both string- and atom-keyed attribute maps for heartbeats.
  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
