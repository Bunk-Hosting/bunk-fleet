defmodule ControlPlaneWeb.BillingControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Billing
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @now ~U[2026-06-25 12:00:00Z]
  @from "2026-06-25T11:00:00Z"
  @to "2026-06-25T13:00:00Z"
  @password "super-secret-pw-123"

  defp insert_region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()
  end

  defp insert_node(region) do
    %Node{}
    |> Node.changeset(%{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      owner_email: "op@example.com"
    })
    # Only :online, recently-heartbeating nodes are metered.
    |> Ecto.Changeset.put_change(:status, :online)
    |> Ecto.Changeset.put_change(
      :last_heartbeat_at,
      DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.insert!()
  end

  defp user_fixture(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # Creates an active VPS owned by `user` and meters one 3600s slice ending @now.
  defp meter_one_hour(region, node, user) do
    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      status: :active,
      vcpu: 2,
      ram_mb: 2048,
      disk_gb: 20,
      owner_id: user.id,
      last_metered_at: DateTime.add(@now, -3600, :second)
    })
    |> Ecto.Changeset.put_change(:status, :active)
    |> Repo.insert!()

    Billing.meter_active_vpses(@now)
  end

  defp auth(conn, user) do
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  setup do
    region = insert_region()
    node = insert_node(region)

    %{
      region: region,
      node: node,
      user: user_fixture("a@example.com"),
      other: user_fixture("b@example.com")
    }
  end

  test "requires authentication", %{conn: conn} do
    assert conn |> get(~p"/api/v1/billing/usage") |> json_response(401)
  end

  test "returns the caller's own cost, scoped and serialized", ctx do
    meter_one_hour(ctx.region, ctx.node, ctx.user)
    meter_one_hour(ctx.region, ctx.node, ctx.other)

    body =
      ctx.conn
      |> auth(ctx.user)
      |> get(~p"/api/v1/billing/usage?from=#{@from}&to=#{@to}")
      |> json_response(200)

    assert body["total_seconds"] == 3600
    assert body["total_cost"] == "0.032000"
    assert [vps] = body["vpses"]
    assert vps["seconds"] == 3600
    assert vps["cost"] == "0.032000"
  end

  test "defaults the window when from/to are omitted", ctx do
    # No metered usage in the default last-30-days window → zero, not an error.
    body = ctx.conn |> auth(ctx.user) |> get(~p"/api/v1/billing/usage") |> json_response(200)
    assert body["total_seconds"] == 0
    assert body["vpses"] == []
  end

  test "400 for a malformed datetime", ctx do
    assert %{"error" => "invalid_datetime"} =
             ctx.conn
             |> auth(ctx.user)
             |> get(~p"/api/v1/billing/usage?from=nonsense&to=#{@to}")
             |> json_response(400)
  end

  test "400 when from is not before to", ctx do
    assert ctx.conn
           |> auth(ctx.user)
           |> get(~p"/api/v1/billing/usage?from=#{@to}&to=#{@from}")
           |> json_response(400)
  end
end
