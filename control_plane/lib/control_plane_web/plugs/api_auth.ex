defmodule ControlPlaneWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates an end-user/operator API request by its bearer session token,
  supplied as an `Authorization: Bearer <session_token>` header.

  The token is transported as URL-safe Base64 (no padding) and decoded here before
  lookup via `ControlPlane.Accounts.get_user_by_session_token/1`. On success the
  authenticated `ControlPlane.Accounts.User` is assigned to
  `conn.assigns.current_user`. On any failure (missing/malformed header, undecodable
  or unknown/expired token) the connection is halted with a `401` JSON body
  `{"error": "unauthorized"}`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Accounts

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, encoded} <- bearer_token(conn),
         {:ok, token} <- Base.url_decode64(encoded, padding: false),
         %Accounts.User{} = user <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ -> unauthorized(conn)
    end
  end

  # The token alphabet is URL-safe Base64 (no whitespace), so we match the header
  # strictly rather than trimming — a malformed header is an auth failure, not
  # something to silently repair. An empty token short-circuits to :error.
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
