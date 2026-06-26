defmodule ControlPlane.Overlay do
  @moduledoc """
  WireGuard overlay coordination. The control plane is the hub; each worker node
  is a spoke. On enrollment a node sends its WireGuard public key and receives the
  hub's public key + UDP endpoint + an assigned overlay IP, so the control plane
  can reach VPSes on that worker over the tunnel (needed for the console and any
  remote-worker access). This module owns the hub keypair (a DB singleton) and
  overlay-IP allocation; the dataplane (wg interfaces/routing) is applied by the
  generated configs on the real hosts.
  """
  import Ecto.Query

  alias ControlPlane.Repo
  alias ControlPlane.Overlay.Config
  alias ControlPlane.Fleet.Node

  @hub_ip "10.99.0.1"
  @cidr "10.99.0.0/16"
  @range_start "10.99.0.2"
  @range_end "10.99.255.254"

  def hub_ip, do: @hub_ip
  def overlay_cidr, do: @cidr

  @doc "The hub's UDP endpoint for WireGuard (host:port). Override via :overlay_endpoint."
  def endpoint do
    case Application.get_env(:control_plane, :overlay_endpoint) do
      ep when is_binary(ep) and ep != "" ->
        ep

      _ ->
        host =
          (Application.get_env(:control_plane, :public_url) || "https://localhost")
          |> URI.parse()
          |> Map.get(:host) || "localhost"

        host <> ":51820"
    end
  end

  @doc "The hub keypair, generated + persisted once."
  def hub_keypair do
    case Repo.get(Config, 1) do
      %Config{} = cfg ->
        cfg

      nil ->
        {pub, priv} = :crypto.generate_key(:ecdh, :x25519)

        %Config{id: 1, hub_private_key: Base.encode64(priv), hub_public_key: Base.encode64(pub)}
        |> Repo.insert(on_conflict: :nothing, conflict_target: :id)

        Repo.get(Config, 1)
    end
  end

  def hub_public_key, do: hub_keypair().hub_public_key

  @doc "Records a node's WireGuard public key and assigns it an overlay IP (idempotent)."
  def register_node(node_id, wg_public_key) when is_binary(wg_public_key) do
    node = Repo.get!(Node, node_id)
    ip = node.overlay_ip || allocate_overlay_ip()

    node
    |> Node.changeset(%{wg_public_key: wg_public_key, overlay_ip: ip})
    |> Repo.update()
  end

  @doc "Next free overlay /32, or nil when the range is exhausted."
  def allocate_overlay_ip do
    used =
      Repo.all(from n in Node, where: not is_nil(n.overlay_ip), select: n.overlay_ip)
      |> Enum.flat_map(fn ip -> if valid?(ip), do: [ip_to_int(ip)], else: [] end)
      |> MapSet.new()

    s = ip_to_int(@range_start)
    e = ip_to_int(@range_end)

    case Enum.find(s..e, fn n -> not MapSet.member?(used, n) end) do
      nil -> nil
      n -> int_to_ip(n)
    end
  end

  @doc "The overlay parameters returned to a node at enrollment."
  def node_overlay_params(%Node{overlay_ip: ip}) when is_binary(ip) do
    %{
      hub_public_key: hub_public_key(),
      endpoint: endpoint(),
      hub_ip: @hub_ip,
      overlay_ip: ip,
      overlay_cidr: @cidr
    }
  end

  def node_overlay_params(_), do: nil

  defp valid?(ip) do
    case String.split(ip, ".") do
      [_, _, _, _] = p -> Enum.all?(p, &match?({_, ""}, Integer.parse(&1)))
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
