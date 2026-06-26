defmodule ControlPlaneWeb.UserSessionMfaTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Accounts

  @pw "Rookworst31!secure"

  defp mfa_user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @pw})
    u = Accounts.start_totp_setup(u)
    {:ok, u} = Accounts.confirm_totp(u, NimbleTOTP.verification_code(u.totp_secret))
    u
  end

  test "login without MFA goes straight to /app", %{conn: conn} do
    {:ok, _} = Accounts.register_user(%{email: "plain@bunk.test", password: @pw})
    conn = post(conn, ~p"/login", %{user: %{email: "plain@bunk.test", password: @pw}})
    assert redirected_to(conn) == ~p"/app"
    assert get_session(conn, :user_token)
  end

  test "login with MFA active requires the second factor", %{conn: conn} do
    u = mfa_user("mfa@bunk.test")

    conn = post(conn, ~p"/login", %{user: %{email: "mfa@bunk.test", password: @pw}})
    assert redirected_to(conn) == ~p"/login/mfa"
    refute get_session(conn, :user_token)
    assert get_session(conn, :mfa_pending_user_id) == u.id

    bad = post(conn, ~p"/login/mfa", %{totp: %{code: "000000"}})
    assert html_response(bad, 401) =~ "Ongeldige code"
    refute get_session(bad, :user_token)

    good = post(conn, ~p"/login/mfa", %{totp: %{code: NimbleTOTP.verification_code(u.totp_secret)}})
    assert redirected_to(good) == ~p"/app"
    assert get_session(good, :user_token)
  end

  test "wrong password never reaches the MFA step", %{conn: conn} do
    mfa_user("mfa2@bunk.test")
    conn = post(conn, ~p"/login", %{user: %{email: "mfa2@bunk.test", password: "wrong-password-xx"}})
    assert html_response(conn, 401) =~ "Ongeldig"
    refute get_session(conn, :mfa_pending_user_id)
  end

  test "the challenge page redirects to /login without a pending login", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/login/mfa")) == ~p"/login"
  end
end
