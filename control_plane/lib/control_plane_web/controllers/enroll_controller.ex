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
      agent_version: Map.get(params, "agent_version")
    }

    case Enrollment.enroll(token, attrs) do
      {:ok, %{node: node, agent_token: agent_token}} ->
        conn
        |> put_status(:ok)
        |> json(%{node_id: node.id, agent_token: agent_token})

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
