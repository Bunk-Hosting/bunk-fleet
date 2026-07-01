defmodule ControlPlaneWeb.Plugs.RequireAdmin do
  @moduledoc """
  Authorizes the session-authenticated admin panel API: requires an
  already-authenticated `current_user` (see `ControlPlaneWeb.Plugs.ApiAuth`, which
  must run first) whose role is exactly `:admin`.

  Anything less — `:operator`, `:user`, or a missing `current_user` — is halted
  with `403 {"error": "forbidden"}`. This gates `/api/v1/admin/*` off the caller's
  own session token (unlike `/admin/v1/*`, which uses a shared secret).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Accounts.User

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: %User{role: :admin}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
    |> halt()
  end
end
