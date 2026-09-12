defmodule ControlPlane.Net do
  @moduledoc """
  Small IPv4 helpers shared by the IP allocator and node-network validation —
  one home for the dotted-quad <-> 32-bit conversion and the octet-range check.
  """

  @doc "True if `value` is a dotted-quad IPv4 with every octet in 0..255."
  def valid?(value) when is_binary(value) do
    case String.split(value, ".") do
      [_, _, _, _] = parts ->
        Enum.all?(parts, fn p -> match?({n, ""} when n >= 0 and n <= 255, Integer.parse(p)) end)

      _ ->
        false
    end
  end

  def valid?(_), do: false

  @doc "Packs a dotted-quad into its 32-bit integer (assumes `valid?/1`)."
  def to_int(ip) do
    [a, b, c, d] = ip |> String.split(".") |> Enum.map(&String.to_integer/1)
    a * 16_777_216 + b * 65_536 + c * 256 + d
  end

  @doc """
  The address out of a Proxmox-native `ip_config` string, or nil.

  The string looks like `ip=10.10.4.20/22,gw=10.10.4.1`. Returns nil for anything
  that does not carry a valid dotted-quad, so a malformed config cannot become an
  address the control plane then treats as authoritative.
  """
  def from_ip_config(config) when is_binary(config) do
    case Regex.run(~r/\bip=(\d+\.\d+\.\d+\.\d+)/, config) do
      [_, ip] -> if valid?(ip), do: ip, else: nil
      _ -> nil
    end
  end

  def from_ip_config(_), do: nil

  @doc "Unpacks a 32-bit integer back into a dotted-quad string."
  def from_int(n) do
    "#{div(n, 16_777_216)}.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end
end
