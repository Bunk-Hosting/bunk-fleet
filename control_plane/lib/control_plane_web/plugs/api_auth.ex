defmodule ControlPlaneWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates an end-user/operator API request by its session token, supplied
  either as an `Authorization: Bearer <session_token>` header (API clients) or as
  the HttpOnly `bunk_session` cookie (browser flow) — see
  `ControlPlaneWeb.Plugs.Bearer.session_token/1`.

  The token is transported as URL-safe Base64 (no padding) and decoded here before
  lookup via `ControlPlane.Accounts.get_user_by_session_token/1`. On success the
  authenticated `ControlPlane.Accounts.User` is assigned to
  `conn.assigns.current_user`. On any failure (missing/malformed token, undecodable
  or unknown/expired token) the connection is halted with a `401` JSON body
  `{"error": "unauthorized"}`.
  """
  import Plug.Conn

  alias ControlPlaneWeb.Plugs.Bearer

  alias ControlPlane.Accounts

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, encoded} <- Bearer.session_token(conn),
         {:ok, token} <- Base.url_decode64(encoded, padding: false),
         %Accounts.User{} = user <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ -> Bearer.unauthorized(conn)
    end
  end

end
