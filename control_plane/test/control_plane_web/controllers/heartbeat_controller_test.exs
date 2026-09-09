defmodule ControlPlaneWeb.HeartbeatControllerTest do
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

  # Enrolls a node end-to-end and returns its id plus the plaintext agent token.
  defp enroll_node(region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: 3600
      })

    {:ok, %{node: node, agent_token: agent_token}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    %{node: node, agent_token: agent_token}
  end

  setup [:create_region]

  describe "POST /v1/heartbeat" do
    test "valid bearer returns 204 and updates node totals and status", %{
      conn: conn,
      region: region
    } do
      %{node: node, agent_token: agent_token} = enroll_node(region)

      body = %{
        "node_id" => node.id,
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "total_vcpu" => 32,
        "avail_vcpu" => 16,
        "total_ram_mb" => 65_536,
        "avail_ram_mb" => 32_768,
        "total_disk_gb" => 1000,
        "avail_disk_gb" => 500
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", body)

      assert response(conn, 204)

      updated = Repo.get!(Node, node.id)
      assert updated.total_vcpu == 32
      assert updated.total_ram_mb == 65_536
      assert updated.total_disk_gb == 1000
      assert updated.status == :online
      refute is_nil(updated.last_heartbeat_at)
    end

    test "missing bearer returns 401", %{conn: conn, region: region} do
      %{node: node} = enroll_node(region)

      conn = post(conn, ~p"/v1/heartbeat", %{"node_id" => node.id})

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "bad bearer returns 401", %{conn: conn, region: region} do
      %{node: node} = enroll_node(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post(~p"/v1/heartbeat", %{"node_id" => node.id})

      assert %{"error" => _} = json_response(conn, 401)
    end
  end
end
