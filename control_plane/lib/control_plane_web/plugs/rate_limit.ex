defmodule ControlPlaneWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client fixed-window rate limiting for open endpoints (login/registration),
  backed by `ControlPlane.RateLimiter`.

  Configure in a pipeline:

      plug ControlPlaneWeb.Plugs.RateLimit, bucket: "auth", max: 30, window_ms: 60_000

  Achter een inlog hoort `by: :user`. Een emmer per IP is daar het verkeerde
  hokje: kantoorgenoten achter één adres duwen elkaar eruit, terwijl iemand die
  het er juist om doet gewoon van netwerk wisselt. Wie is ingelogd heeft een
  identiteit die niet meewisselt, en die kost hem een nieuwe registratie om te
  vervangen. Zonder ingelogde gebruiker valt het terug op het IP.

  The client is identified by `CF-Connecting-IP` (set by Cloudflare, which the
  client cannot forge), falling back to `conn.remote_ip`. We deliberately do NOT
  trust the left-most `X-Forwarded-For` hop, which is client-supplied and would
  let an attacker rotate a fake hop to get unlimited buckets. On exceeding `max`
  requests within `window_ms` the connection is halted with `429` + `Retry-After`
  and `{"error": "rate_limited"}`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.RateLimiter

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      max: Keyword.fetch!(opts, :max),
      window_ms: Keyword.fetch!(opts, :window_ms),
      by: Keyword.get(opts, :by, :ip)
    }
  end

  @impl true
  def call(conn, %{bucket: bucket, max: max, window_ms: window_ms} = opts) do
    key = bucket <> ":" <> wie(conn, Map.get(opts, :by, :ip))

    case RateLimiter.hit(key, max, window_ms) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(window_ms, 1000)))
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited"})
        |> halt()
    end
  end

  defp wie(conn, :user) do
    case conn.assigns[:current_user] do
      %{id: id} -> "u:" <> to_string(id)
      # Geen gebruiker in de assigns: dan staat deze plug vóór de authenticatie
      # of is het verzoek afgekeurd. Terugvallen op het IP is hier het veilige
      # antwoord -- niet limiteren zou betekenen dat je de rem omzeilt door je
      # token weg te laten.
      _ -> client_ip(conn)
    end
  end

  defp wie(conn, _ip), do: client_ip(conn)

  defp client_ip(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) and ip != "" ->
        ip

      _ ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
