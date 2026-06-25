defmodule ControlPlaneWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client fixed-window rate limiting for open endpoints (login/registration),
  backed by `ControlPlane.RateLimiter`.

  Configure in a pipeline:

      plug ControlPlaneWeb.Plugs.RateLimit, bucket: "auth", max: 30, window_ms: 60_000

  The client is identified by the first `X-Forwarded-For` hop when present (the
  control plane runs behind a trusted proxy / Cloudflare), falling back to
  `conn.remote_ip`. On exceeding `max` requests within `window_ms`, the connection
  is halted with `429` + a `Retry-After` header and `{"error": "rate_limited"}`.

  NOTE: trusting `X-Forwarded-For` is only safe behind a proxy that overwrites it;
  exposed directly to the internet a client could spoof it to dodge the limit.
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
      window_ms: Keyword.fetch!(opts, :window_ms)
    }
  end

  @impl true
  def call(conn, %{bucket: bucket, max: max, window_ms: window_ms}) do
    key = bucket <> ":" <> client_ip(conn)

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

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] when is_binary(forwarded) ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      _ ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
