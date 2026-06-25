defmodule ControlPlaneWeb.HeartbeatController do
  @moduledoc """
  Handles `POST /v1/heartbeat`: an authenticated node reports its advertised
  capacity. Authentication (bearer agent token -> `current_node`) is performed by
  `ControlPlaneWeb.Plugs.NodeAuth` before this action runs.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet

  def create(conn, %{"node_id" => node_id} = params) do
    node = conn.assigns.current_node

    if node.id == node_id do
      total_attrs =
        Map.take(params, ["total_vcpu", "total_ram_mb", "total_disk_gb"])

      case Fleet.mark_online_heartbeat(node, total_attrs) do
        {:ok, _node} ->
          send_resp(conn, :no_content, "")

        {:error, _changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid heartbeat"})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "node_id mismatch"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing node_id"})
  end
end
