defmodule ControlPlaneWeb.HeartbeatControllerTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

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

    test "een agent zonder zicht op zijn hypervisor blijft online, met de reden", %{
      conn: conn,
      region: region
    } do
      # Dit is het geval waarvoor dit bestaat. Tot nu toe stuurde zo'n agent
      # helemaal niets, waarna de node na twee minuten offline ging -- niet te
      # onderscheiden van een machine die uit staat, en precies de informatie
      # kwijt die nodig is om het op te lossen.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      gezond = fn ->
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{
          "node_id" => node.id,
          "total_vcpu" => 8,
          "avail_vcpu" => 8,
          "total_ram_mb" => 16_384,
          "avail_ram_mb" => 16_384,
          "total_disk_gb" => 500,
          "avail_disk_gb" => 500
        })
      end

      assert response(gezond.(), 204)

      kapot =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{
          "node_id" => node.id,
          "total_vcpu" => 0,
          "avail_vcpu" => 0,
          "total_ram_mb" => 0,
          "avail_ram_mb" => 0,
          "total_disk_gb" => 0,
          "avail_disk_gb" => 0,
          "capacity_error" => "proxmox: dial tcp 10.0.0.9:8006: connect: no route to host"
        })

      assert response(kapot, 204)

      updated = Repo.get!(Node, node.id)
      assert updated.status == :online
      assert updated.capacity_error =~ "no route to host"

      # De laatst bekende totalen blijven staan: die zeggen nog steeds wat deze
      # machine is. De nullen in het bericht zijn geen meting.
      assert updated.total_vcpu == 8
      assert updated.total_ram_mb == 16_384
      assert updated.total_disk_gb == 500

      # Maar er mag niets meer op geplaatst worden zolang hij niet kan kijken.
      assert updated.reported_avail_vcpu == 0
      assert updated.reported_avail_ram_mb == 0
      assert updated.reported_avail_disk_gb == 0
    end

    test "een geslaagde heartbeat wist de eerdere melding", %{conn: conn, region: region} do
      # Anders blijft een opgelost probleem in het paneel staan, en leert een
      # beheerder de melding te negeren.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      stuur = fn extra ->
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(
          ~p"/v1/heartbeat",
          Map.merge(
            %{
              "node_id" => node.id,
              "total_vcpu" => 4,
              "avail_vcpu" => 4,
              "total_ram_mb" => 8192,
              "avail_ram_mb" => 8192,
              "total_disk_gb" => 100,
              "avail_disk_gb" => 100
            },
            extra
          )
        )
      end

      assert response(stuur.(%{"capacity_error" => "geen verbinding"}), 204)
      assert Repo.get!(Node, node.id).capacity_error == "geen verbinding"

      assert response(stuur.(%{}), 204)
      assert is_nil(Repo.get!(Node, node.id).capacity_error)
      assert Repo.get!(Node, node.id).reported_avail_ram_mb == 8192
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
