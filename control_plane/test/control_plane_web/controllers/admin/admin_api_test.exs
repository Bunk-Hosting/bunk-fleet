defmodule ControlPlaneWeb.Admin.AdminApiTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Repo
  alias ControlPlane.Enrollment
  alias ControlPlane.Provisioning
  alias ControlPlane.Fleet.{Region, Vps}

  @admin_token "test-admin-token"

  defp create_region(_) do
    region =
      %Region{}
      |> Region.changeset(%{code: "nl-1", name: "Netherlands 1"})
      |> Repo.insert!()

    %{region: region}
  end

  defp auth(conn, token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # Enrolls a node in `region` and seeds it with capacity so VPSes can be placed.
  defp enroll_node_with_capacity(region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: 3600
      })

    {:ok, %{node: node}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    node
    |> Ecto.Changeset.change(
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    )
    |> Repo.update!()
  end

  # Creates a VPS and drives it to :active so it has a provider_vm_id (the
  # precondition for deletion).
  defp active_vps(region) do
    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "vps-test",
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20,
        owner_email: "ops@bunkhosting.nl",
        template_id: 9000
      })

    {:ok, _command} =
      Provisioning.apply_result(command, %{
        "status" => "done",
        "vm_id" => "10101",
        "ip" => "10.10.0.10",
        "error" => nil
      })

    Repo.get!(Vps, vps.id)
  end

  describe "admin token authentication" do
    test "missing admin token returns 401", %{conn: conn} do
      conn = get(conn, ~p"/admin/v1/regions")
      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "wrong admin token returns 401", %{conn: conn} do
      conn =
        conn
        |> auth("not-the-token")
        |> get(~p"/admin/v1/regions")

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end
  end

  describe "with a valid admin token" do
    setup %{conn: conn} do
      {:ok, conn: auth(conn, @admin_token)}
    end

    test "creates a region", %{conn: conn} do
      conn =
        post(conn, ~p"/admin/v1/regions", %{
          "code" => "de-1",
          "name" => "Germany 1"
        })

      assert %{"region" => region} = json_response(conn, 201)
      assert region["code"] == "de-1"
      assert region["name"] == "Germany 1"
      assert is_binary(region["id"])
      assert Repo.get_by(Region, code: "de-1")
    end

    test "lists regions", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn = get(conn, ~p"/admin/v1/regions")

      assert %{"regions" => regions} = json_response(conn, 200)
      assert Enum.any?(regions, &(&1["code"] == region.code))
    end

    test "creates an enroll token and returns plaintext + install string", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn =
        post(conn, ~p"/admin/v1/enroll-tokens", %{
          "region_code" => region.code,
          "ttl_seconds" => 3600
        })

      assert %{
               "enroll_token" => enroll_token,
               "install" => install,
               "region" => region_code
             } = json_response(conn, 201)

      assert is_binary(enroll_token)
      assert region_code == region.code
      # The wizard, not a container: only an agent installed on the hypervisor
      # host can configure the customer bridge it is assigned.
      assert install =~ "/install.sh"
      assert install =~ "--token " <> enroll_token
      refute install =~ "docker run"
    end

    test "lists nodes (empty is ok)", %{conn: conn} do
      conn = get(conn, ~p"/admin/v1/nodes")
      assert %{"nodes" => nodes} = json_response(conn, 200)
      assert nodes == []
    end

    test "creating a vps with no nodes available returns 409 no_capacity", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn =
        post(conn, ~p"/admin/v1/vpses", %{
          "region_code" => region.code,
          "name" => "vps-test",
          "vcpu" => 2,
          "ram_mb" => 2048,
          "disk_gb" => 20,
          "owner_email" => "ops@bunkhosting.nl"
        })

      assert %{"error" => "no_capacity"} = json_response(conn, 409)
    end

    test "deletes a vps, returning 202 and moving it to :deleting", %{conn: conn} do
      %{region: region} = create_region(%{})
      _node = enroll_node_with_capacity(region)
      vps = active_vps(region)

      conn = delete(conn, ~p"/admin/v1/vpses/#{vps.id}")

      assert %{"vps" => body} = json_response(conn, 202)
      assert body["id"] == vps.id
      assert body["status"] == "deleting"

      assert Repo.get!(Vps, vps.id).status == :deleting
    end

    test "deleting an unknown vps returns 404", %{conn: conn} do
      conn = delete(conn, ~p"/admin/v1/vpses/#{Ecto.UUID.generate()}")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
