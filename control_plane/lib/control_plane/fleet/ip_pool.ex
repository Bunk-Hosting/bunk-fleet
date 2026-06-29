defmodule ControlPlane.Fleet.IpPool do
  @moduledoc """
  Minimal IPv4 allocator for customer VPSes.

  Hands out the next free address from the configured `:vps_network` range,
  treating any address already held by a non-`:deleted` VPS as in use. This keeps
  customers from having to know networking: `create_vps_for_owner/2` calls
  `allocate/0` when no explicit `ip_config` is supplied.

  Config (`config :control_plane, :vps_network, ...`): `prefix`, `gateway`,
  `range_start`, `range_end`.
  """
  import Ecto.Query

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{Node, Vps}
  alias ControlPlane.Net

  @doc """
  Allocates the next free address. Returns `{:ok, %{ip: ip, config: ip_config}}`
  where `ip_config` is the Proxmox-native string (`ip=.../prefix,gw=...`), or
  `{:error, :pool_exhausted}` when the range is full.
  """
  def allocate(node \\ nil) do
    net = node_network(node)
    start_n = Net.to_int(net.range_start)
    end_n = Net.to_int(net.range_end)

    cond do
      start_n > end_n ->
        {:error, :pool_exhausted}

      true ->
        allocate_in_range(start_n, end_n, net)
    end
  end

  defp allocate_in_range(start_n, end_n, net) do
    used = used_ips(start_n, end_n)

    case Enum.find(start_n..end_n, fn n -> not MapSet.member?(used, n) end) do
      nil ->
        {:error, :pool_exhausted}

      n ->
        ip = Net.from_int(n)
        {:ok, %{ip: ip, config: "ip=#{ip}/#{net.prefix},gw=#{net.gateway}"}}
    end
  end

  # A node's own VPS network when it declared one at enrollment, else the global
  # default range. This keeps existing single-network workers working while
  # letting each worker bring its own subnet.
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

  # IPs in use within the given numeric range only — so a per-node subnet is not
  # blocked by addresses handed out on a different worker's subnet.
  defp used_ips(start_n, end_n) do
    Repo.all(
      from v in Vps,
        where: not is_nil(v.ip_address) and v.status != :deleted,
        select: v.ip_address
    )
    |> Enum.flat_map(fn ip -> if Net.valid?(ip), do: [Net.to_int(ip)], else: [] end)
    |> Enum.filter(fn n -> n >= start_n and n <= end_n end)
    |> MapSet.new()
  end

end
