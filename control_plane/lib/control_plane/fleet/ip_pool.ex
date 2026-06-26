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
  alias ControlPlane.Fleet.Vps

  @doc """
  Allocates the next free address. Returns `{:ok, %{ip: ip, config: ip_config}}`
  where `ip_config` is the Proxmox-native string (`ip=.../prefix,gw=...`), or
  `{:error, :pool_exhausted}` when the range is full.
  """
  def allocate do
    net = Application.get_env(:control_plane, :vps_network, []) |> Enum.into(%{})
    prefix = Map.get(net, :prefix, 19)
    gw = Map.get(net, :gateway, "10.10.0.1")
    start_n = ip_to_int(Map.get(net, :range_start, "10.10.0.20"))
    end_n = ip_to_int(Map.get(net, :range_end, "10.10.4.254"))

    used = used_ips()

    case Enum.find(start_n..end_n, fn n -> not MapSet.member?(used, n) end) do
      nil ->
        {:error, :pool_exhausted}

      n ->
        ip = int_to_ip(n)
        {:ok, %{ip: ip, config: "ip=#{ip}/#{prefix},gw=#{gw}"}}
    end
  end

  defp used_ips do
    Repo.all(
      from v in Vps,
        where: not is_nil(v.ip_address) and v.status != :deleted,
        select: v.ip_address
    )
    |> Enum.flat_map(fn ip -> if valid?(ip), do: [ip_to_int(ip)], else: [] end)
    |> MapSet.new()
  end

  defp valid?(ip) do
    case String.split(ip, ".") do
      [_, _, _, _] = parts -> Enum.all?(parts, &match?({_, ""}, Integer.parse(&1)))
      _ -> false
    end
  end

  defp ip_to_int(ip) do
    [a, b, c, d] = ip |> String.split(".") |> Enum.map(&String.to_integer/1)
    a * 16_777_216 + b * 65_536 + c * 256 + d
  end

  defp int_to_ip(n) do
    "#{div(n, 16_777_216)}.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end
end
