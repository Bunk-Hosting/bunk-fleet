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

  @doc "Unpacks a 32-bit integer back into a dotted-quad string."
  def from_int(n) do
    "#{div(n, 16_777_216)}.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end
end
