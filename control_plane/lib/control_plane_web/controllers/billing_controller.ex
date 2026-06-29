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
  `ControlPlane.Billing`). `total_cost` is the authoritative figure (computed
  exactly over all records); the per-VPS `cost` line items are each individually
  rounded for display and may sum to a sub-cent less/more than `total_cost`.
  Authenticated by `ControlPlaneWeb.Plugs.ApiAuth`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Billing
  alias ControlPlaneWeb.TimeWindow

  def usage(conn, params) do
    with {:ok, {from, to}} <- TimeWindow.parse(params) do
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
        bad_request(conn, "invalid_datetime", "from and to must be ISO8601 datetimes")

      {:error, :invalid_window} ->
        bad_request(conn, "invalid_window", "from must be earlier than to")
    end
  end

  # --- helpers --------------------------------------------------------------

  defp vps_json(%{vps_id: vps_id, name: name, seconds: seconds, cost: cost}) do
    %{vps_id: vps_id, name: name, seconds: seconds, cost: Decimal.to_string(cost)}
  end

  defp bad_request(conn, code, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: code, detail: detail})
  end
end
