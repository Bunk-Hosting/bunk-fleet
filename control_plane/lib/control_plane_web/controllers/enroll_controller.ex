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
      }
    }

    case Enrollment.enroll(token, attrs) do
      {:ok, %{node: node, agent_token: agent_token}} ->
        # The agent needs its VPS network back: the control plane may have
        # assigned the block rather than taken the agent's word for it, and the
        # agent is what configures the bridge and NAT from it.
        body = %{
          node_id: node.id,
          agent_token: agent_token,
          vps_network: %{
            gateway: node.vps_gateway,
            cidr_prefix: node.vps_cidr_prefix,
            range_start: node.vps_range_start,
            range_end: node.vps_range_end
          }
        }

        conn
        |> put_status(:ok)
        |> json(body)

      {:error, :supernet_exhausted} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "supernet_exhausted"})

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
