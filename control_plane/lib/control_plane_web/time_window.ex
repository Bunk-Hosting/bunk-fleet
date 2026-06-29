defmodule ControlPlaneWeb.TimeWindow do
  @moduledoc """
  Parses + validates a half-open `[from, to)` datetime window from request params,
  shared by the billing / operator / admin metering endpoints.

  `parse/2` reads `params["from"]` and `params["to"]` (ISO8601). With
  `require: false` (default) a missing `to` is now and a missing `from` is
  `to - 30d`; with `require: true` both must be present. `from` must precede `to`.
  Returns `{:ok, {from, to}}` or `{:error, :invalid_datetime | :invalid_window}`.
  """
  @default_window_days 30

  def parse(params, opts \\ []) do
    required? = Keyword.get(opts, :require, false)

    with {:ok, to} <- one(params["to"], required?, fn -> default_to() end),
         {:ok, from} <- one(params["from"], required?, fn -> default_from(to) end),
         :ok <- validate(from, to) do
      {:ok, {from, to}}
    end
  end

  defp one(nil, true, _default), do: {:error, :invalid_datetime}
  defp one(nil, false, default), do: {:ok, default.()}

  defp one(value, _required?, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp one(_value, _required?, _default), do: {:error, :invalid_datetime}

  defp default_to, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp default_from(to), do: DateTime.add(to, -@default_window_days * 24 * 3600, :second)

  defp validate(from, to) do
    if DateTime.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_window}
  end
end
