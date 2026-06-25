defmodule ControlPlaneWeb.OperatorControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.{Accounts, Billing, Enrollment, Repo}
  alias ControlPlane.Fleet.{Region, Vps}

  @now ~U[2026-06-25 12:00:00Z]
  @password "super-secret-pw-123"

  defp insert_region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()
  end

  defp operator_fixture(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, operator} = Accounts.update_user_role(user, :operator)
    operator
  end

  defp user_fixture(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp auth(conn, user) do
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # Mints a token for `operator` and enrolls a node, returning the node.
  defp enroll_node(operator, region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token_for_operator(operator, %{
        region_id: region.id,
        tier: :community,
        ttl_seconds: 3600
      })

    {:ok, %{node: node}} = Enrollment.enroll(plaintext, %{hypervisor: :proxmox})
    node
  end

  setup do
    %{region: insert_region(), operator: operator_fixture("op@example.com")}
  end

  # --- role gate -------------------------------------------------------------

  describe "role gate" do
    test "401 without a token", %{conn: conn} do
      assert conn |> get(~p"/api/v1/operator/nodes") |> json_response(401)
    end

    test "403 for a plain :user", %{conn: conn} do
      user = user_fixture("plain@example.com")
      assert %{"error" => "forbidden"} =
               conn |> auth(user) |> get(~p"/api/v1/operator/nodes") |> json_response(403)
    end
  end

  # --- enroll tokens ---------------------------------------------------------

  describe "POST /api/v1/operator/enroll-tokens" do
    test "mints a token bound to the operator with an install command", ctx do
      body =
        ctx.conn
        |> auth(ctx.operator)
        |> post(~p"/api/v1/operator/enroll-tokens", %{"region_code" => ctx.region.code})
        |> json_response(201)

      assert is_binary(body["enroll_token"])
      assert body["region"] == ctx.region.code
      assert body["install"] =~ "BUNK_ENROLL_TOKEN=#{body["enroll_token"]}"

      # A node enrolling with this token inherits the operator as owner.
      {:ok, %{node: node}} = Enrollment.enroll(body["enroll_token"], %{hypervisor: :proxmox})
      assert node.owner_email == ctx.operator.email
    end

    test "422 for an unknown region", ctx do
      assert %{"error" => "region_not_found"} =
               ctx.conn
               |> auth(ctx.operator)
               |> post(~p"/api/v1/operator/enroll-tokens", %{"region_code" => "nope"})
               |> json_response(422)
    end
  end

  # --- nodes -----------------------------------------------------------------

  describe "GET /api/v1/operator/nodes" do
    test "lists only the operator's own nodes", ctx do
      mine = enroll_node(ctx.operator, ctx.region)
      other_op = operator_fixture("other-op@example.com")
      _theirs = enroll_node(other_op, ctx.region)

      body = ctx.conn |> auth(ctx.operator) |> get(~p"/api/v1/operator/nodes") |> json_response(200)
      assert [node] = body["nodes"]
      assert node["id"] == mine.id
    end
  end

  # --- earnings --------------------------------------------------------------

  describe "GET /api/v1/operator/earnings" do
    test "reports the payout for usage the operator's node hosted", ctx do
      node = enroll_node(ctx.operator, ctx.region)

      # An active VPS on the node, last metered an hour before @now.
      %Vps{}
      |> Vps.changeset(%{
        name: "vps-1",
        region_id: ctx.region.id,
        node_id: node.id,
        status: :active,
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20,
        last_metered_at: DateTime.add(@now, -3600, :second)
      })
      |> Ecto.Changeset.put_change(:status, :active)
      |> Repo.insert!()

      assert Billing.meter_active_vpses(@now) == 1

      from = "2026-06-25T11:00:00Z"
      to = "2026-06-25T13:00:00Z"

      body =
        ctx.conn
        |> auth(ctx.operator)
        |> get(~p"/api/v1/operator/earnings?from=#{from}&to=#{to}")
        |> json_response(200)

      assert body["seconds"] == 3600
      assert body["records"] == 1
      # 3600 * (2*0.010*1024 + 2048*0.004 + 20*0.0002*1024) / (3600*1024) = 0.032000
      assert body["amount"] == "0.032000"
    end

    test "defaults the window and reports zero with no usage", ctx do
      body = ctx.conn |> auth(ctx.operator) |> get(~p"/api/v1/operator/earnings") |> json_response(200)
      assert body["seconds"] == 0
      assert body["amount"] == "0.000000"
    end
  end
end
