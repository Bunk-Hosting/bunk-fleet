defmodule ControlPlaneWeb.VpsControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.{Accounts, Provisioning}
  alias ControlPlane.Fleet.{Node, Region}

  @password "super-secret-pw-123"

  # --- fixtures --------------------------------------------------------------

  defp insert_region(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Region #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp insert_node(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    })
    |> Repo.insert!()
  end

  defp user_fixture(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password, name: "U"})
    user
  end

  defp auth(conn, user) do
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp create_vps_for(user, region, name) do
    {:ok, %{vps: vps}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: name,
        vcpu: 2,
        ram_mb: 4096,
        disk_gb: 50,
        owner_id: user.id,
        owner_email: user.email,
        template_id: 9000
      })

    vps
  end

  setup do
    region = insert_region()
    _node = insert_node(region)
    %{region: region, user: user_fixture("owner@example.com"), other: user_fixture("other@example.com")}
  end

  # --- auth gate -------------------------------------------------------------

  test "rejects unauthenticated requests", %{conn: conn} do
    assert conn |> get(~p"/api/v1/vpses") |> json_response(401)
  end

  # --- index -----------------------------------------------------------------

  describe "GET /api/v1/vpses" do
    test "lists only the caller's own VPSes", %{conn: conn, region: region, user: user, other: other} do
      mine = create_vps_for(user, region, "mine")
      _theirs = create_vps_for(other, region, "theirs")

      assert %{"vpses" => [vps]} = conn |> auth(user) |> get(~p"/api/v1/vpses") |> json_response(200)
      assert vps["id"] == mine.id
      assert vps["name"] == "mine"
    end
  end

  # --- create ----------------------------------------------------------------

  describe "POST /api/v1/vpses" do
    test "provisions a VPS owned by the caller", %{conn: conn, region: region, user: user} do
      params = %{"region_id" => region.id, "name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50}

      assert %{"vps" => vps} = conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(201)
      assert vps["name"] == "web"
      # Owner fields are never echoed, and ownership came from the session.
      refute Map.has_key?(vps, "owner_email")
      assert [persisted] = ControlPlane.Fleet.list_vpses_for_owner(user.id)
      assert persisted.id == vps["id"]
    end

    test "ignores an owner_id supplied in the body (no spoofing)", %{conn: conn, region: region, user: user, other: other} do
      params = %{"region_id" => region.id, "name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50, "owner_id" => other.id}

      assert conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(201)
      assert ControlPlane.Fleet.list_vpses_for_owner(other.id) == []
      assert [_one] = ControlPlane.Fleet.list_vpses_for_owner(user.id)
    end

    test "resolves a region_code", %{conn: conn, region: region, user: user} do
      params = %{"region_code" => region.code, "name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50}
      assert conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(201)
    end

    test "422 for an unknown region", %{conn: conn, user: user} do
      params = %{"region_code" => "nope", "name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50}
      assert %{"error" => "region_not_found"} =
               conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(422)
    end
  end

  # --- show / delete ownership ----------------------------------------------

  describe "ownership enforcement" do
    test "show returns 404 for another user's VPS", %{conn: conn, region: region, user: user, other: other} do
      theirs = create_vps_for(other, region, "theirs")
      assert %{"error" => "not_found"} =
               conn |> auth(user) |> get(~p"/api/v1/vpses/#{theirs.id}") |> json_response(404)
    end

    test "show returns 404 for a malformed id", %{conn: conn, user: user} do
      assert conn |> auth(user) |> get(~p"/api/v1/vpses/not-a-uuid") |> json_response(404)
    end

    test "delete refuses another user's VPS and leaves it intact", %{conn: conn, region: region, user: user, other: other} do
      theirs = create_vps_for(other, region, "theirs")

      assert conn |> auth(user) |> delete(~p"/api/v1/vpses/#{theirs.id}") |> json_response(404)
      # Still owned by `other`, untouched.
      assert [still] = ControlPlane.Fleet.list_vpses_for_owner(other.id)
      assert still.id == theirs.id
    end

    test "owner can see their own VPS", %{conn: conn, region: region, user: user} do
      mine = create_vps_for(user, region, "mine")
      assert %{"vps" => %{"id" => id}} =
               conn |> auth(user) |> get(~p"/api/v1/vpses/#{mine.id}") |> json_response(200)
      assert id == mine.id
    end
  end
end
