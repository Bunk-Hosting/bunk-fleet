defmodule ControlPlaneWeb.BillingController do
  @moduledoc """
  End-user billing API: the authenticated owner's own metered usage and cost.

  `GET /api/v1/billing/usage?from=&to=` returns the cost breakdown for the
  half-open window `[from, to)` across the caller's VPSes only (scoped by
  `current_user.id` via `ControlPlane.Billing.customer_usage/2`). `from`/`to` are
  ISO8601 datetimes; when omitted they default to the last 30 days ending now, so
  a dashboard can call the endpoint with no arguments. `from` must precede `to`.

  Money values are serialized as strings to preserve `Decimal` precision; the
  unit is whatever `:control_plane, :billing_rates` configures (see
  `ControlPlane.Billing`). Authenticated by `ControlPlaneWeb.Plugs.ApiAuth`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Billing

  @default_window_days 30

  def usage(conn, params) do
    with {:ok, to} <- parse_datetime(params["to"], default_to()),
         {:ok, from} <- parse_datetime(params["from"], default_from(to)),
         :ok <- validate_window(from, to) do
      usage = Billing.customer_usage(conn.assigns.current_user.id, {from, to})

      json(conn, %{
        from: DateTime.to_iso8601(from),
        to: DateTime.to_iso8601(to),
        total_seconds: usage.total_seconds,
        total_cost: Decimal.to_string(usage.total_cost),
        vpses: Enum.map(usage.vpses, &vps_json/1)
      })
    else
      {:error, :invalid_datetime} ->
        bad_request(conn, "from and to must be ISO8601 datetimes")

      {:error, :invalid_window} ->
        bad_request(conn, "from must be earlier than to")
    end
  end

  # --- helpers --------------------------------------------------------------

  defp vps_json(%{vps_id: vps_id, name: name, seconds: seconds, cost: cost}) do
    %{vps_id: vps_id, name: name, seconds: seconds, cost: Decimal.to_string(cost)}
  end

  defp default_to, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp default_from(to), do: DateTime.add(to, -@default_window_days * 24 * 3600, :second)

  # Parses an ISO8601 datetime, falling back to `default` when the param is absent.
  defp parse_datetime(nil, default), do: {:ok, default}

  defp parse_datetime(value, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value, _default), do: {:error, :invalid_datetime}

  defp validate_window(from, to) do
    if DateTime.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_window}
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_window", detail: detail})
  end
end
