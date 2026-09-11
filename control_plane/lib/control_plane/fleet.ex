defmodule ControlPlane.Fleet do
  @moduledoc """
  The Fleet context: regions, nodes, VPSes and capacity reservations that make up
  the federated VPS control plane.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Repo
  alias Ecto.Multi
  alias ControlPlane.Fleet.{Events, Node, Package, Region, Reservation, Vps}

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
  def list_nodes(opts \\ []) do
    Repo.all(
      from n in Node,
        order_by: [desc: n.inserted_at],
        limit: ^Keyword.get(opts, :limit, 500),
        preload: [:region]
    )
  end

  @doc """
  Returns the nodes attributed to the cost centre `owner_email` (matching
  `nodes.owner_email`), region preloaded, newest first.
  """
  def list_nodes_for_owner(owner_email) do
    Repo.all(
      from n in Node,
        where: n.owner_email == ^owner_email,
        order_by: [desc: n.inserted_at],
        preload: [:region]
    )
  end

  @doc """
  Removes a node from the fleet.

  Refuses with `{:error, :node_has_vpses}` while the node still hosts any live
  (non-`:deleted`/`:failed`) VPS, so removing a node can never orphan a running
  customer VM — those must be torn down first. On success the node's commands and
  reservations cascade-delete and any dead VPSes' `node_id` is nilified. Returns
  `{:error, :not_found}` for an unknown id.

  Note: the node's agent (if still running) keeps its persisted credentials, so
  its next heartbeat will 401 against the now-missing node — stop/uninstall the
  agent on that machine after removal.
  """
  def delete_node(node_id) do
    case Repo.get(Node, node_id) do
      nil ->
        {:error, :not_found}

      %Node{} = node ->
        live =
          Repo.aggregate(
            from(v in Vps, where: v.node_id == ^node_id and v.status not in [:deleted, :failed]),
            :count
          )

        if live > 0 do
          {:error, :node_has_vpses}
        else
          Repo.delete(node)
        end
    end
  end

  @doc """
  Returns all VPSes, with their region preloaded, newest first.
  """
  def list_vpses(opts \\ []) do
    Repo.all(
      from v in Vps,
        order_by: [desc: v.inserted_at],
        limit: ^Keyword.get(opts, :limit, 500),
        preload: [:region]
    )
  end

  @doc "Available VPS packages, ordered like the catalog (sort_order, price)."
  def list_available_packages do
    Repo.all(
      from p in Package,
        where: p.is_available == true,
        order_by: [asc: p.sort_order, asc: p.price_monthly]
    )
  end

  def get_package(id), do: Repo.get(Package, id)

  @doc """
  The available package whose specs exactly match `vcpu`/`ram_mb`/`disk_gb`, or
  `nil`. Lets a self-service VPS be priced from the catalogue server-side rather
  than trusting any client-supplied price — an unmatched spec is simply rejected.
  """
  def package_for_specs(vcpu, ram_mb, disk_gb) do
    with v when is_integer(v) <- coerce_int(vcpu),
         m when is_integer(m) <- coerce_int(ram_mb),
         d when is_integer(d) <- coerce_int(disk_gb),
         # RAM must be an exact whole-GB match. Without this, ram_mb=3000 rounds
         # via div(m,1024)=2 to the 2 GB package's price while ~3 GB is actually
         # provisioned — underpay + silent oversell of real node capacity.
         true <- rem(m, 1024) == 0 do
      Repo.one(
        from p in Package,
          where:
            p.is_available == true and p.cpu_cores == ^v and
              p.ram_gb == ^div(m, 1024) and p.disk_gb == ^d,
          limit: 1
      )
    else
      _ -> nil
    end
  end

  defp coerce_int(v) when is_integer(v), do: v

  defp coerce_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp coerce_int(_), do: nil

  @doc "The default region for self-service create (the old app is single-region)."
  def default_region do
    Repo.one(from r in Region, order_by: [asc: r.code], limit: 1)
  end

  @doc """
  Returns the VPSes owned by `owner_id`, region preloaded, newest first.
  """
  def list_vpses_for_owner(owner_id) do
    # Exclude :deleted — a torn-down VPS must vanish from the customer's list
    # (the frontend renders whatever this returns), not linger as a ghost row.
    Repo.all(
      from v in Vps,
        where: v.owner_id == ^owner_id and v.status != :deleted,
        order_by: [desc: v.inserted_at],
        preload: [:region]
    )
  end

  @doc """
  Fetches a single VPS by `id`, but only if it is owned by `owner_id`.

  Returns `nil` when the VPS does not exist *or* belongs to another owner — the
  caller cannot distinguish the two, so this doubles as the authorization check.
  """
  def get_vps_for_owner(owner_id, id) do
    Repo.one(
      from v in Vps,
        where: v.id == ^id and v.owner_id == ^owner_id,
        preload: [:region]
    )
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

    # PERF: only a real status transition (offline/pending -> online) or the
    # first heartbeat (which seeds available_*) is UI-relevant. A routine
    # heartbeat just refreshes last_heartbeat_at/total_*, so it must NOT broadcast
    # — otherwise every node's heartbeat forces every connected dashboard to a
    # full reload (O(nodes x dashboards) per interval). Capacity changes are
    # broadcast by the scheduler, and offline transitions by the reconciler.
    transition? = node.status != :online or is_nil(node.available_vcpu)

    node
    |> Node.mark_online_changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn _node -> if transition?, do: Events.broadcast_changed(:node) end)
  end

  # Runs `fun` only when `result` is `{:ok, value}`, then returns `result`
  # unchanged. Used to fire a best-effort PubSub event as a side-effect after a
  # successful DB write without altering the function's return value.
  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result

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

    query =
      from n in Node,
        where:
          n.status == :online and
            not is_nil(n.last_heartbeat_at) and
            n.last_heartbeat_at >= ^cutoff

    if is_nil(region_id), do: query, else: where(query, [n], n.region_id == ^region_id)
  end

  @doc """
  The region to place `request` in when the customer did not pick one.

  Picks the region of the node that would be left with the most headroom — the
  same measure the scheduler uses to choose between nodes, applied one level up,
  so "automatic" lands on the emptiest machine in the fleet rather than on
  whichever region happens to sort first.

  Advisory only: nothing is locked here. The scheduler still makes the real
  decision inside its transaction, and may pick a different node in the region if
  this one filled up in between.
  """
  def auto_region_id(%{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb} = request) do
    online_nodes_in_region_query(nil)
    |> where(
      [n],
      n.available_vcpu >= ^vcpu and n.available_ram_mb >= ^ram_mb and
        n.available_disk_gb >= ^disk_gb
    )
    |> Repo.all()
    |> case do
      [] -> {:error, :no_capacity}
      nodes -> {:ok, Enum.max_by(nodes, &Node.headroom_score(&1, request)).region_id}
    end
  end

  @doc """
  Regions a customer can currently be placed in: those with at least one online
  node reporting free capacity.

  A region with no node behind it is not a choice, it is a disappointment —
  listing it would let someone pick a location we cannot actually deliver.
  """
  def available_regions do
    node_ids =
      online_nodes_in_region_query(nil)
      |> where([n], n.available_vcpu > 0 and n.available_ram_mb > 0 and n.available_disk_gb > 0)
      |> select([n], n.region_id)

    from(r in Region, where: r.id in subquery(node_ids), order_by: [asc: r.code])
    |> Repo.all()
  end

  @doc false
  def heartbeat_ttl_seconds, do: @heartbeat_ttl_seconds

  @doc """
  Flips stale `:online` nodes to `:offline`, returning `{count, _}`.

  A node whose agent has stopped reporting keeps `status: :online` in the database
  indefinitely — the `@heartbeat_ttl_seconds` TTL only hides it from the scheduler
  (see `online_nodes_in_region_query/1`), so the operator dashboard and status
  checks would still show a dead node as online. This reconciliation step makes
  that staleness explicit: it sets `status = :offline` for every node that is
  currently `:online` and whose `last_heartbeat_at` is either null or older than
  the heartbeat TTL.

  Only `:online` nodes are affected. `:draining`, `:pending` and already-`:offline`
  nodes are deliberately left untouched (e.g. an operator-initiated drain must not
  be undone by reconciliation), and `available_*` capacity — owned solely by the
  scheduler — is never modified. The update runs as a single `Repo.update_all`.

  See `mark_stale_nodes_offline/1` to pass an explicit cutoff (useful in tests).
  """
  def mark_stale_nodes_offline do
    mark_stale_nodes_offline(DateTime.add(now(), -@heartbeat_ttl_seconds, :second))
  end

  @doc """
  Like `mark_stale_nodes_offline/0`, but flips `:online` nodes whose
  `last_heartbeat_at` is null or strictly older than the given `cutoff` datetime.
  """
  def mark_stale_nodes_offline(%DateTime{} = cutoff) do
    query =
      from n in Node,
        where:
          n.status == :online and
            (is_nil(n.last_heartbeat_at) or n.last_heartbeat_at < ^cutoff)

    {count, _} = result = Repo.update_all(query, set: [status: :offline, updated_at: now()])

    if count > 0, do: Events.broadcast_changed(:nodes_offline)

    result
  end

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

  @doc """
  Reclaims capacity reservations that are still `:held` but no longer back a live
  VPS — the VPS was deleted/failed, or the reservation was orphaned (null `vps_id`)
  by a rolled-back placement. Each reclaimed reservation is marked `:released` and
  its vcpu/ram/disk are added back to its node's advertised capacity, so a leaked
  reservation can never keep a node wrongly reported as "full".

  Reservations backing a VPS that is still `:queued`/`:provisioning`/`:active`
  (or `:stopped`/`:paused`/`:deleting`) are left untouched — those hold capacity
  for a real workload. Returns the number of reservations reclaimed.
  """
  def release_orphaned_reservations do
    orphaned =
      Repo.all(
        from r in Reservation,
          left_join: v in Vps,
          on: v.id == r.vps_id,
          where: r.status == :held and (is_nil(r.vps_id) or v.status in [:deleted, :failed])
      )

    Enum.reduce(orphaned, 0, fn reservation, reclaimed ->
      case release_reservation(reservation) do
        {:ok, _} -> reclaimed + 1
        {:error, _} -> reclaimed
      end
    end)
  end

  # Atomically marks a held reservation released and returns its capacity to the node.
  defp release_reservation(%Reservation{} = reservation) do
    Multi.new()
    |> Multi.update(:reservation, Reservation.changeset(reservation, %{status: :released}))
    |> Multi.run(:restore_capacity, fn repo, _changes ->
      Node.add_capacity(repo, reservation)
    end)
    |> Repo.transaction()
  end
end
