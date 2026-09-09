defmodule ControlPlaneWeb.EnrollControllerTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Repo
  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.{Node, Region}

  defp create_region(_) do
    region =
      %Region{}
      |> Region.changeset(%{code: "nl-1", name: "Netherlands 1"})
      |> Repo.insert!()

    %{region: region}
  end

  defp create_enroll_token(region, ttl_seconds \\ 3600) do
    {:ok, {plaintext, token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: ttl_seconds
      })

    {plaintext, token}
  end

  setup [:create_region]

  describe "POST /v1/enroll" do
    test "valid token returns 200 with node_id and agent_token and creates an online node",
         %{conn: conn, region: region} do
      {plaintext, _token} = create_enroll_token(region)

      conn =
        post(conn, ~p"/v1/enroll", %{
          "token" => plaintext,
          "hypervisor" => "proxmox",
          "agent_version" => "1.2.3"
        })

      assert %{"node_id" => node_id, "agent_token" => agent_token} = json_response(conn, 200)
      assert is_binary(node_id)
      assert is_binary(agent_token)

      node = Repo.get!(Node, node_id)
      assert node.region_id == region.id
      assert node.status == :online
      assert node.hypervisor == :proxmox
      refute is_nil(node.last_heartbeat_at)
      refute is_nil(node.agent_token_hash)
    end

    test "invalid token returns 401", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/enroll", %{
          "token" => "definitely-not-a-real-token",
          "hypervisor" => "proxmox",
          "agent_version" => "1.2.3"
        })

      assert %{"error" => _} = json_response(conn, 401)
    end
  end
end
