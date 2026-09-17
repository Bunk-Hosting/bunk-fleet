defmodule ControlPlane.Mollie do
  @moduledoc """
  Thin client for the Mollie Payments API.

  Mollie does NOT sign webhooks. The webhook body carries only a payment `id`;
  the integrity model is **fetch-to-verify** — we always re-fetch the payment
  from Mollie (authenticated with the secret API key) to learn its real status
  before crediting anything. A forged webhook id therefore either isn't found in
  our DB or fetches a non-"paid" status, and crediting is idempotent.
  """
  require Logger

  @base "https://api.mollie.com/v2"

  def configured?, do: is_binary(api_key()) and api_key() != ""

  @doc """
  Creates a payment. `params` requires :amount_cents, :description, :redirect_url,
  :webhook_url and may include :metadata. Returns {:ok, %{id, checkout_url,
  status}}.
  """
  def create_payment(params) do
    body = %{
      amount: %{currency: "EUR", value: euro_string(params.amount_cents)},
      description: params.description,
      redirectUrl: params.redirect_url,
      webhookUrl: params.webhook_url,
      metadata: Map.get(params, :metadata, %{})
    }

    case Req.post(req(), url: "/payments", json: body) do
      {:ok, %{status: s, body: b}} when s in 200..201 ->
        {:ok,
         %{
           id: b["id"],
           checkout_url: get_in(b, ["_links", "checkout", "href"]),
           status: b["status"]
         }}

      {:ok, %{status: s, body: b}} ->
        Logger.warning("mollie create_payment http #{s}")
        {:error, {:mollie_http, s, b}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc "Fetches a payment to verify its real status. Returns {:ok, %{id, status, amount, metadata}}."
  def get_payment(id) when is_binary(id) do
    case Req.get(req(), url: "/payments/" <> id) do
      {:ok, %{status: 200, body: b}} ->
        {:ok, %{id: b["id"], status: b["status"], amount: b["amount"], metadata: b["metadata"]}}

      {:ok, %{status: s, body: b}} ->
        {:error, {:mollie_http, s, b}}

      {:error, e} ->
        {:error, e}
    end
  end

  # Mollie wants the amount as a string with exactly 2 decimals; format from the
  # integer cents to avoid any float rounding error on money.
  defp euro_string(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)}." <>
      (rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  # `:req_options` is how the test suite points this client at a stub instead of
  # api.mollie.com. Nothing sets it in production, and the two lines that read it
  # are the only difference between what the tests exercise and what runs live —
  # the request building, the status handling and the money parsing are shared.
  defp req do
    [
      base_url: @base,
      auth: {:bearer, api_key()},
      # Een betaling aanmaken gebeurt terwijl een klant naar een laadscherm
      # kijkt, en de webhook die hier ook langskomt is ongeauthenticeerd. Zonder
      # eigen grens erft dit Req's standaard: vijftien seconden per poging, en
      # dan nog een paar keer opnieuw. Eén trage Mollie hield dan bijna een
      # minuut lang een verbinding uit de pool bezig, en de pool is er tien.
      #
      # Niet opnieuw proberen is hier bewust. Deze aanroepen maken betalingen
      # aan; een herhaling van iets waarvan we niet weten of het is aangekomen
      # is precies hoe je twee betalingen krijgt voor één bestelling. Mislukt
      # het, dan zegt dit scherm dat, en dan klikt de klant zelf opnieuw.
      receive_timeout: 8_000,
      connect_options: [timeout: 4_000],
      retry: false
    ]
    |> Keyword.merge(config(:req_options) || [])
    |> Req.new()
  end

  defp api_key, do: config(:api_key)

  defp config(key), do: Application.get_env(:control_plane, :mollie, [])[key]
end
