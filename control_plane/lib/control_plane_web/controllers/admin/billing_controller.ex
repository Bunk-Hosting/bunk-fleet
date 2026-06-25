defmodule ControlPlaneWeb.Admin.BillingController do
  @moduledoc """
  Operator/admin API for metered usage and operator payouts.

  `usage` (GET `/admin/v1/billing/usage?from=&to=`) returns the per-operator
  payout summary for the window. `from`/`to` are ISO8601 datetimes (e.g.
  `2026-06-01T00:00:00Z`); both are required. `amount` is a money value in the
  unit configured via `:control_plane, :billing_rates` (see
  `ControlPlane.Billing` for the model and units), serialized as a string to
  preserve Decimal precision.

  Protected by `ControlPlaneWeb.Plugs.AdminAuth` (shared-secret admin token).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Billing

  def usage(conn, params) do
    with {:ok, from} <- parse_datetime(params["from"]),
         {:ok, to} <- parse_datetime(params["to"]) do
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
        |> json(%{error: "invalid_window", detail: "from and to must be ISO8601 datetimes"})
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

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}
end
