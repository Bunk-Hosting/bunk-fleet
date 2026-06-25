defmodule ControlPlane.Fleet do
  @moduledoc """
  The Fleet context: regions, nodes, VPSes and capacity reservations that make up
  the federated VPS control plane.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Node, Region, Vps}

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
  Fetches a single region by id, raising `Ecto.NoResultsError` if none exists.
  """
  def get_region!(id), do: Repo.get!(Region, id)

  @doc """
  Fetches a single region by its unique `code` (e.g. "nl-1").

  Returns the `%Region{}` or `nil` if no region has that code.
  """
  def region_by_code(code) when is_binary(code) do
    Repo.get_by(Region, code: code)
  end

  @doc """
  Creates a region from the given attributes.
  """
  def create_region(attrs) do
    %Region{}
    |> Region.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all nodes, with their region preloaded, newest first.
  """
  def list_nodes do
    Repo.all(from n in Node, order_by: [desc: n.inserted_at], preload: [:region])
  end

  @doc """
  Returns all VPSes, with their region preloaded, newest first.
  """
  def list_vpses do
    Repo.all(from v in Vps, order_by: [desc: v.inserted_at], preload: [:region])
  end

  @doc """
  Registers (enrolls) a new node in the fleet.

  On enrollment the node's live `available_*` capacity is initialised to its
  advertised `total_*` (unless explicitly provided), since a fresh node hosts no
  VPSes yet. From then on `available_*` is owned solely by the scheduler.
  """
  def register_node(attrs) do
    %Node{}
    |> Node.changeset(default_available(normalize_keys(attrs)))
    |> Repo.insert()
  end

  defp default_available(attrs) do
    attrs
    |> Map.put_new(:available_vcpu, attrs[:total_vcpu])
    |> Map.put_new(:available_ram_mb, attrs[:total_ram_mb])
    |> Map.put_new(:available_disk_gb, attrs[:total_disk_gb])
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
  Applies an authenticated heartbeat from a node: refreshes its advertised `total_*`
  capacity and `last_heartbeat_at`, and (re)asserts the node as `:online`.

  The `:online` status transition is trusted server-side logic (the node's agent
  token has already been authenticated), so it is applied here via
  `Node.mark_online_changeset/2` rather than the agent-driven
  `Node.heartbeat_changeset/2`. As with all heartbeats, `available_*` is never
  touched — that remains owned solely by the scheduler.

  `total_attrs` may use either atom or string keys and is expected to carry
  `total_vcpu` / `total_ram_mb` / `total_disk_gb`.
  """
  def mark_online_heartbeat(%Node{} = node, total_attrs) do
    totals =
      total_attrs
      |> normalize_keys()
      |> Map.take([:total_vcpu, :total_ram_mb, :total_disk_gb])

    attrs =
      totals
      |> Map.put(:last_heartbeat_at, now())
      |> Map.put(:status, :online)
      |> maybe_init_available(node, totals)

    node
    |> Node.mark_online_changeset(attrs)
    |> Repo.update()
  end

  # A node enrolls before it has reported any capacity, so `available_*` starts
  # nil. On the FIRST heartbeat (which establishes total_*) we seed available_*
  # to the totals — a fresh node hosts no VPSes. After that, available_* is owned
  # exclusively by the scheduler and heartbeats never touch it again.
  defp maybe_init_available(attrs, %Node{available_vcpu: nil}, totals) do
    attrs
    |> Map.put(:available_vcpu, totals[:total_vcpu])
    |> Map.put(:available_ram_mb, totals[:total_ram_mb])
    |> Map.put(:available_disk_gb, totals[:total_disk_gb])
  end

  defp maybe_init_available(attrs, %Node{}, _totals), do: attrs

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
