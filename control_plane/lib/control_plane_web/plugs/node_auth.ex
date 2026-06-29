defmodule ControlPlaneWeb.Plugs.NodeAuth do
  @moduledoc """
  Authenticates a worker node by its long-lived agent token, supplied as an
  `Authorization: Bearer <agent_token>` header.

  On success the authenticated `ControlPlane.Fleet.Node` is assigned to
  `conn.assigns.current_node`. On any failure (missing/malformed header or unknown
  token) the connection is halted with a `401` JSON body `{"error": "..."}`.
  """
  import Plug.Conn

  alias ControlPlaneWeb.Plugs.Bearer

  alias ControlPlane.Enrollment

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- Bearer.token(conn),
         {:ok, node} <- Enrollment.authenticate_node(token) do
      assign(conn, :current_node, node)
    else
      _ -> Bearer.unauthorized(conn)
    end
  end

end
