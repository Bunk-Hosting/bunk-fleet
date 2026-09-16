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
      # De agent meldt zowel zijn totalen als wat hij daarvan nog vrij ziet. Dat
      # laatste gaat naar reported_avail_*, niet naar available_*: dat laatste is
      # van de scheduler en mag niet door een heartbeat overschreven worden.
      #
      # `capacity_error` is de uitzondering op "een heartbeat meldt capaciteit":
      # een agent die zijn hypervisor niet kan bevragen hoort alsnog te melden dat
      # hij leeft, met de reden erbij. Zonder dat is hij niet te onderscheiden van
      # een machine die uit staat.
      total_attrs =
        params
        |> Map.take([
          "total_vcpu",
          "total_ram_mb",
          "total_disk_gb",
          "agent_version",
          "capacity_error"
        ])
        |> Map.merge(%{
          "reported_avail_vcpu" => params["avail_vcpu"],
          "reported_avail_ram_mb" => params["avail_ram_mb"],
          "reported_avail_disk_gb" => params["avail_disk_gb"]
        })

      case Fleet.mark_online_heartbeat(node, total_attrs) do
        {:ok, _node} ->
          send_resp(conn, :no_content, "")

        {:error, _changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_heartbeat"})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "node_id_mismatch"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing_node_id"})
  end
end
