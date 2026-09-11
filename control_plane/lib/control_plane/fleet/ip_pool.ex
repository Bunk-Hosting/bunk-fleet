defmodule ControlPlane.Fleet.IpPool do
  @moduledoc """
  IPv4 allocator for customer VPSes, scoped to the node the VPS is being placed on.

  Every node runs its own layer-2 VPS network (see `ControlPlane.Fleet.Subnets`),
  so an address is only "in use" relative to *that* node's network. Allocation
  therefore looks at the VPSes on the node it is allocating for and nothing else:
  a busy node can never exhaust a quiet node's pool, and the node a VPS lands on
  is the node whose gateway ends up in its cloud-init.

  Callers hold a per-node advisory lock (`ControlPlane.Provisioning`) so two
  concurrent creates on one node cannot pick the same address, with the
  `vpses_active_node_ip_uidx` unique index as the database backstop.

  A node without a recorded network falls back to the configured global default
  (`config :control_plane, :vps_network`). That is the pre-`Subnets` shape and is
  kept so an older row or a test fixture still allocates; every node enrolled
  since gets its own block.
  """
  import Ecto.Query

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Node, Vps}
  alias ControlPlane.Net

  @doc """
  Allocates the next free address on `node`. Returns `{:ok, %{ip: ip, config: ip_config}}`
  where `ip_config` is the Proxmox-native string (`ip=.../prefix,gw=...`), or
  `{:error, :pool_exhausted}` when the node's range is full.
  """
  def allocate(node \\ nil) do
    net = node_network(node)
    start_n = Net.to_int(net.range_start)
    end_n = Net.to_int(net.range_end)

    if start_n > end_n do
      {:error, :pool_exhausted}
    else
      allocate_in_range(start_n, end_n, net, node)
    end
  end

  defp allocate_in_range(start_n, end_n, net, node) do
    used = used_ips(node)

    case Enum.find(start_n..end_n, fn n -> not MapSet.member?(used, n) end) do
      nil ->
        {:error, :pool_exhausted}

      n ->
        ip = Net.from_int(n)
        {:ok, %{ip: ip, config: "ip=#{ip}/#{net.prefix},gw=#{net.gateway}"}}
    end
  end

  # A node's own VPS network when it has one, else the global default range. This
  # keeps rows that predate per-node blocks working.
  defp node_network(%Node{vps_range_start: rs, vps_range_end: re} = node)
       when is_binary(rs) and is_binary(re) do
    g = global_network()

    %{
      prefix: node.vps_cidr_prefix || g.prefix,
      gateway: node.vps_gateway || g.gateway,
      range_start: rs,
      range_end: re
    }
  end

  defp node_network(_), do: global_network()

  defp global_network do
    net = Application.get_env(:control_plane, :vps_network, []) |> Enum.into(%{})

    %{
      prefix: Map.get(net, :prefix, 19),
      gateway: Map.get(net, :gateway, "10.10.0.1"),
      range_start: Map.get(net, :range_start, "10.10.0.20"),
      range_end: Map.get(net, :range_end, "10.10.4.254")
    }
  end

  # Addresses live in a node's own network, so only that node's live VPSes occupy
  # them. Rows not yet placed (node_id nil) hold no address, and :deleted rows
  # release theirs.
  defp used_ips(node) do
    Vps
    |> where([v], not is_nil(v.ip_address) and v.status != :deleted)
    |> scope_to_node(node)
    |> select([v], v.ip_address)
    |> Repo.all()
    |> Enum.flat_map(fn ip -> if Net.valid?(ip), do: [Net.to_int(ip)], else: [] end)
    |> MapSet.new()
  end

  defp scope_to_node(query, %Node{id: id}), do: where(query, [v], v.node_id == ^id)

  # No node means the legacy single-network path: every live address is a peer.
  defp scope_to_node(query, _nil), do: query
end
