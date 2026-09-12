defmodule ControlPlaneWeb.AuthTotpTest do
  @moduledoc "Tests for the TOTP two-factor endpoints exposed for the frontend."
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Accounts

  defp authed_conn(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer " <> Base.url_encode64(token, padding: false))
  end

  defp user(email) do
    {:ok, u} =
      Accounts.register_user(%{email: email, password: "test-only-password-4f2b9c1e", name: "T"})

    u
  end

  describe "TOTP endpoints" do
    test "setup requires authentication", %{conn: conn} do
      assert get(conn, ~p"/api/v1/auth/totp/setup").status == 401
    end

    test "/auth/me reports totp_enabled false before setup", %{conn: conn} do
      conn = authed_conn(conn, user("totp_me@bunk.test"))
      body = conn |> get(~p"/api/v1/auth/me") |> json_response(200)
      refute body["user"]["totp_enabled"]
    end

    test "setup returns a secret and an SVG QR data URL", %{conn: conn} do
      conn = authed_conn(conn, user("totp_setup@bunk.test"))
      body = conn |> get(~p"/api/v1/auth/totp/setup") |> json_response(200)
      assert is_binary(body["secret"]) and byte_size(body["secret"]) > 0
      assert String.starts_with?(body["qr_data_url"], "data:image/svg+xml;base64,")
    end

    test "confirm rejects a wrong code with 422", %{conn: conn} do
      conn = authed_conn(conn, user("totp_wrong@bunk.test"))
      conn |> get(~p"/api/v1/auth/totp/setup") |> json_response(200)
      body = conn |> post(~p"/api/v1/auth/totp/setup", %{code: "000000"}) |> json_response(422)
      assert body["error"] == "invalid_code"
    end

    test "full enable -> me:true -> disable -> me:false cycle", %{conn: conn} do
      u = user("totp_cycle@bunk.test")
      conn = authed_conn(conn, u)

      conn |> get(~p"/api/v1/auth/totp/setup") |> json_response(200)
      secret = Accounts.get_user!(u.id).totp_secret

      assert conn
             |> post(~p"/api/v1/auth/totp/setup", %{code: NimbleTOTP.verification_code(secret)})
             |> json_response(200)

      assert conn
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["user", "totp_enabled"])

      assert conn
             |> delete(~p"/api/v1/auth/totp/disable", %{code: "000000"})
             |> json_response(422)

      assert conn
             |> delete(~p"/api/v1/auth/totp/disable", %{
               code: NimbleTOTP.verification_code(secret)
             })
             |> json_response(200)

      refute conn
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["user", "totp_enabled"])
    end
  end
end
