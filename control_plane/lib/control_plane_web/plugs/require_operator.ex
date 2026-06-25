defmodule ControlPlaneWeb.Plugs.RequireOperator do
  @moduledoc """
  Authorizes the operator API: requires an already-authenticated `current_user`
  (see `ControlPlaneWeb.Plugs.ApiAuth`, which must run first) whose role is
  `:operator` or `:admin`.

  A plain `:user` — or a missing `current_user`, which shouldn't happen behind
  `ApiAuth` but is handled defensively — is halted with `403 {"error":
  "forbidden"}`. Admins are allowed through so they retain a superset of operator
  capabilities.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Accounts.User

  @behaviour Plug

  @allowed_roles [:operator, :admin]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: %User{role: role}}} = conn, _opts)
      when role in @allowed_roles do
    conn
  end

  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
    |> halt()
  end
end
