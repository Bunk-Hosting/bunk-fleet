defmodule ControlPlaneWeb.Plugs.Bearer do
  @moduledoc """
  Shared `Authorization: Bearer <token>` handling for the auth plugs: extract a
  trimmed, non-empty token (an empty or whitespace-only token is never valid), and
  the common `401 {"error": "unauthorized"}` halt.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc "The trimmed, non-empty bearer token from the Authorization header, or `:error`."
  def token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case String.trim(token) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  @cookie "bunk_session"

  @doc "Name of the HttpOnly session cookie set for the browser login flow."
  def cookie_name, do: @cookie

  @doc """
  The session token from the `Authorization: Bearer` header (API clients + agents)
  or, failing that, the HttpOnly `bunk_session` cookie (browser flow). Returns
  `{:ok, token}` or `:error`.

  Preferring the header keeps token-based API/agent callers working unchanged; the
  cookie fallback lets the browser hold the token HttpOnly (never in JS-readable
  storage), so an XSS foothold can't exfiltrate a live session.
  """
  def session_token(conn) do
    case token(conn) do
      {:ok, t} ->
        {:ok, t}

      :error ->
        conn = fetch_cookies(conn)

        case conn.cookies[@cookie] do
          t when is_binary(t) and t != "" -> {:ok, t}
          _ -> :error
        end
    end
  end

  @doc ~S"""
  Halts the connection with 401 and a `{"error": "unauthorized"}` body.

  Also clears the `bunk_session` cookie: if a browser presents a revoked/expired
  cookie it is now dead weight that would otherwise loop the SPA forever between
  /dashboard and /login (the browser keeps re-sending it). A live session never
  reaches here, so clearing it unconditionally is safe; an API/agent caller using
  the Authorization header just ignores the harmless Set-Cookie.
  """
  def unauthorized(conn) do
    conn
    |> delete_resp_cookie(@cookie, path: "/")
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
