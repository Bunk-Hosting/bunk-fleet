defmodule ControlPlaneWeb.MollieController do
  @moduledoc """
  Mollie-backed wallet top-ups.

    * POST /api/v1/billing/topup (authenticated) — creates a Mollie payment for
      the requested amount and returns its hosted checkout URL. A pending
      `topup_request` is recorded, keyed on the Mollie payment id.
    * POST /api/v1/billing/mollie/webhook (public) — Mollie calls this with a
      payment id. We FETCH the payment to verify it is really "paid" before
      crediting the wallet (idempotently). Always answers 200 so Mollie stops
      retrying; the credit work is safe to repeat.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.ApiResponse
  require Logger

  alias ControlPlane.{Credits, Mollie}

  @min_cents 500
  @max_cents 100_000

  def topup(conn, params) do
    user = conn.assigns.current_user

    with {:ok, cents} <- parse_amount(params),
         true <- Mollie.configured?() || {:error, :not_configured},
         {:ok, payment} <-
           Mollie.create_payment(%{
             amount_cents: cents,
             description: "Bunk Hosting tegoed",
             redirect_url: public_url() <> "/dashboard/billing?topup=processing",
             webhook_url: public_url() <> "/api/v1/billing/mollie/webhook",
             metadata: %{user_id: user.id}
           }),
         {:ok, _tr} <- Credits.create_mollie_topup(user.id, cents, payment.id) do
      json(conn, %{checkout_url: payment.checkout_url, payment_id: payment.id})
    else
      {:error, :invalid_amount} ->
        error(conn, :unprocessable_entity, "invalid_amount")

      {:error, :not_configured} ->
        error(conn, :service_unavailable, "payments_unavailable")

      {:error, {:mollie_http, status, body}} when status in 400..499 ->
        # A 4xx from Mollie is a rejected request (e.g. an unregistered redirect
        # domain), not a gateway outage — surface the reason as 422 so it reaches
        # the client (Cloudflare replaces 5xx bodies with its own error page).
        detail = (is_map(body) && body["detail"]) || "betaling geweigerd"
        Logger.warning("mollie rejected topup: #{inspect(body)}")
        conn |> put_status(:unprocessable_entity) |> json(%{error: "payment_rejected", detail: detail})

      {:error, reason} ->
        Logger.warning("topup failed: #{inspect(reason)}")
        error(conn, :bad_gateway, "payment_provider_error")
    end
  end

  def webhook(conn, %{"id" => payment_id}) when is_binary(payment_id) do
    # Validate the id shape BEFORE any outbound fetch: rejects malformed ids (path
    # smuggling into the Mollie API) and cheap garbage that would otherwise fan out
    # one authenticated HTTPS call to Mollie per request.
    if valid_mollie_id?(payment_id) do
      case Mollie.get_payment(payment_id) do
        {:ok, %{status: "paid", amount: amount}} ->
          # Credit only after verifying the amount Mollie actually settled matches
          # the amount we recorded — defence-in-depth against adjustable-amount
          # payment types ever being enabled.
          case Credits.mark_topup_paid_by_mollie_id(payment_id, amount) do
            {:ok, _} -> :ok
            {:error, :not_pending} -> :ok
            {:error, :not_found} -> :ok
            {:error, :amount_mismatch} -> Logger.error("mollie webhook amount mismatch for #{payment_id}")
            other -> Logger.warning("mollie webhook credit: #{inspect(other)}")
          end

        {:ok, %{status: status}} ->
          Logger.info("mollie webhook #{payment_id} status=#{status} (no credit)")

        {:error, reason} ->
          Logger.warning("mollie webhook fetch failed for #{payment_id}: #{inspect(reason)}")
      end
    else
      Logger.info("mollie webhook: ignoring malformed payment id")
    end

    # Always 200: the work is idempotent and we don't want Mollie to retry on our
    # transient errors forever in a way that hammers us.
    send_resp(conn, 200, "")
  end

  def webhook(conn, _params), do: send_resp(conn, 200, "")

  # Mollie payment ids look like `tr_<alnum>`.
  defp valid_mollie_id?(id), do: String.match?(id, ~r/\Atr_[A-Za-z0-9]+\z/)

  defp parse_amount(%{"amount_cents" => v}) do
    cents =
      cond do
        is_integer(v) -> v
        is_binary(v) -> case Integer.parse(v) do
          {n, ""} -> n
          _ -> nil
        end
        true -> nil
      end

    if is_integer(cents) and cents >= @min_cents and cents <= @max_cents,
      do: {:ok, cents},
      else: {:error, :invalid_amount}
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp public_url, do: Application.get_env(:control_plane, :public_url) || ""
end
