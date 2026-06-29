defmodule ControlPlaneWeb.Admin.BillingController do
  @moduledoc """
  Operator/admin API for metered usage and operator payouts.

  `usage` (GET `/admin/v1/billing/usage?from=&to=`) returns the per-operator
  payout summary for the half-open window `[from, to)` (records with
  `metered_at >= from and metered_at < to`, so adjacent windows tile without
  double-counting the boundary). `from`/`to` are ISO8601 datetimes (e.g.
  `2026-06-01T00:00:00Z`); both are required. `amount` is a money value in the
  unit configured via `:control_plane, :billing_rates` (see
  `ControlPlane.Billing` for the model and units), serialized as a string to
  preserve Decimal precision.

  Protected by `ControlPlaneWeb.Plugs.AdminAuth` (shared-secret admin token).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Billing
  alias ControlPlaneWeb.TimeWindow

  def usage(conn, params) do
    with {:ok, {from, to}} <- TimeWindow.parse(params, require: true) do
      summary = Enum.map(Billing.payout_summary({from, to}), &payout_json/1)

      json(conn, %{
        from: DateTime.to_iso8601(from),
        to: DateTime.to_iso8601(to),
        payouts: summary
      })
    else
      {:error, :invalid_datetime} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_datetime", detail: "from and to must be ISO8601 datetimes"})

      {:error, :invalid_window} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_window", detail: "from must be earlier than to"})
    end
  end

  defp payout_json(%{owner_email: owner_email, amount: amount, seconds: seconds, records: records}) do
    %{
      owner_email: owner_email,
      amount: Decimal.to_string(amount),
      seconds: seconds,
      records: records
    }
  end
end
