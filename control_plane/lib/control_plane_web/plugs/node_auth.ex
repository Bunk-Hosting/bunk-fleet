defmodule ControlPlaneWeb.Plugs.NodeAuth do
  @moduledoc """
  Authenticates a worker node by its long-lived agent token, supplied as an
  `Authorization: Bearer <agent_token>` header.

  On success the authenticated `ControlPlane.Fleet.Node` is assigned to
  `conn.assigns.current_node`. On any failure (missing/malformed header or unknown
  token) the connection is halted with a `401` JSON body `{"error": "..."}`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Enrollment

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, node} <- Enrollment.authenticate_node(token) do
      assign(conn, :current_node, node)
    else
      _ -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
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
