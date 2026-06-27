defmodule ControlPlaneWeb.VpsApiExtTest do
  @moduledoc "Tests for the package catalog + VPS power endpoints added for the frontend."
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Accounts

  defp authed_conn(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer " <> Base.url_encode64(token, padding: false))
  end

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Rookworst31!secure", name: "T"})
    u
  end

  describe "GET /api/v1/packages" do
    test "is public and lists the available packages", %{conn: conn} do
      body = conn |> get(~p"/api/v1/packages") |> json_response(200)
      assert body["count"] == 4
      names = Enum.map(body["results"], & &1["name"])
      assert "Starter" in names and "Business" in names
      starter = Enum.find(body["results"], &(&1["name"] == "Starter"))
      assert starter["price_monthly"] == "3.99"
      assert starter["cpu_cores"] == 1
    end
  end

  describe "POST /api/v1/vpses/:id/start|stop" do
    test "404 for an unknown id (existence is never leaked)", %{conn: conn} do
      conn = authed_conn(conn, user("pow1@bunk.test"))
      assert conn |> post(~p"/api/v1/vpses/#{Ecto.UUID.generate()}/start") |> json_response(404)
      assert conn |> post(~p"/api/v1/vpses/#{Ecto.UUID.generate()}/stop") |> json_response(404)
    end

    test "404 for a malformed id", %{conn: conn} do
      conn = authed_conn(conn, user("pow2@bunk.test"))
      assert conn |> post(~p"/api/v1/vpses/not-a-uuid/start") |> json_response(404)
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/vpses/#{Ecto.UUID.generate()}/start")
      assert conn.status == 401
    end
  end
end
