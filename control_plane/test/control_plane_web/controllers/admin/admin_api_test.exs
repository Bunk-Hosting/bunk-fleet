defmodule ControlPlaneWeb.Admin.AdminApiTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.Region

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
          "tier" => "community",
          "ttl_seconds" => 3600
        })

      assert %{
               "enroll_token" => enroll_token,
               "install" => install,
               "region" => region_code
             } = json_response(conn, 201)

      assert is_binary(enroll_token)
      assert region_code == region.code
      assert install =~ "docker run"
      assert install =~ "bunk-agent"
      assert install =~ "BUNK_ENROLL_TOKEN=" <> enroll_token
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
  end
end
