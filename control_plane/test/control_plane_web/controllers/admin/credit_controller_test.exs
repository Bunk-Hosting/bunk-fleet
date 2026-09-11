defmodule ControlPlaneWeb.Admin.CreditControllerTest do
  use ControlPlaneWeb.ConnCase

  import ControlPlane.Fixtures

  alias ControlPlane.Credits

  @admin_token "test-admin-token"

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  # The wallets below start at the signup bonus, which is granted on email
  # confirmation rather than at registration — hence confirmed_user_fixture/1,
  # so these tests see the balance a real onboarded customer has.

  test "admin tops up a wallet", %{conn: conn} do
    u = confirmed_user_fixture("topup@bunk.test")
    start = Credits.balance_cents(u.id)

    conn =
      conn
      |> auth()
      |> post(~p"/admin/v1/credits", %{email: "topup@bunk.test", amount_cents: 500, description: "iDEAL"})

    assert %{"balance_cents" => bal} = json_response(conn, 200)
    assert bal == start + 500
    assert Credits.balance_cents(u.id) == start + 500
  end

  test "negative amount is a correction", %{conn: conn} do
    u = confirmed_user_fixture("corr@bunk.test")
    start = Credits.balance_cents(u.id)
    conn = conn |> auth() |> post(~p"/admin/v1/credits", %{email: "corr@bunk.test", amount_cents: -200})
    assert json_response(conn, 200)["balance_cents"] == start - 200
  end

  test "shows balance + entries", %{conn: conn} do
    confirmed_user_fixture("show@bunk.test")
    conn = conn |> auth() |> get(~p"/admin/v1/credits?email=show@bunk.test")
    body = json_response(conn, 200)
    assert body["balance_cents"] == Credits.signup_bonus_cents()
    assert is_list(body["entries"])
  end

  test "404 for unknown user", %{conn: conn} do
    conn = conn |> auth() |> post(~p"/admin/v1/credits", %{email: "nope@bunk.test", amount_cents: 100})
    assert json_response(conn, 404)
  end

  test "rejects zero amount", %{conn: conn} do
    confirmed_user_fixture("zero@bunk.test")
    conn = conn |> auth() |> post(~p"/admin/v1/credits", %{email: "zero@bunk.test", amount_cents: 0})
    assert json_response(conn, 422)
  end

  test "requires the admin token", %{conn: conn} do
    confirmed_user_fixture("noauth@bunk.test")
    conn = post(conn, ~p"/admin/v1/credits", %{email: "noauth@bunk.test", amount_cents: 100})
    assert conn.status in [401, 403]
  end
end
