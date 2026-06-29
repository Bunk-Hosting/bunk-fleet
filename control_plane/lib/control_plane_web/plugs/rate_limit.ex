defmodule ControlPlaneWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client fixed-window rate limiting for open endpoints (login/registration),
  backed by `ControlPlane.RateLimiter`.

  Configure in a pipeline:

      plug ControlPlaneWeb.Plugs.RateLimit, bucket: "auth", max: 30, window_ms: 60_000

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
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) and ip != "" ->
        ip

      _ ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
