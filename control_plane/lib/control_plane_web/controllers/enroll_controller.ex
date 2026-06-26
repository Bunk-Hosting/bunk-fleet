defmodule ControlPlaneWeb.EnrollController do
  @moduledoc """
  Handles `POST /v1/enroll`: a `bunk-agent` exchanges a single-use enroll token for
  a new node identity and a long-lived agent token.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Enrollment

  def enroll(conn, %{"token" => token} = params) when is_binary(token) do
    attrs = %{
      hypervisor: Map.get(params, "hypervisor", "proxmox"),
      agent_version: Map.get(params, "agent_version"),
      vps_network: %{
        gateway: params["vps_gateway"],
        cidr_prefix: params["vps_cidr_prefix"],
        range_start: params["vps_range_start"],
        range_end: params["vps_range_end"]
      },
      wg_public_key: params["wg_public_key"]
    }

    case Enrollment.enroll(token, attrs) do
      {:ok, %{node: node, agent_token: agent_token} = result} ->
        body = %{node_id: node.id, agent_token: agent_token}
        body = if result[:overlay], do: Map.put(body, :overlay, result.overlay), else: body

        conn
        |> put_status(:ok)
        |> json(body)

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_token"})
    end
  end

  def enroll(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing token"})
  end
end
