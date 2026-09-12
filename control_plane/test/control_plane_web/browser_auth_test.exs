defmodule ControlPlaneWeb.BrowserAuthTest do
  @moduledoc """
  The server-rendered login/registration/logout flow, and the session lifecycle
  underneath it.

  Customers use the Next.js app against the JSON API; this flow is what staff use
  to reach the fleet dashboard, so a session issued here is an admin session. The
  properties asserted are the ones that decide whether a stolen or replayed
  session works: what the cookie holds, whether a pre-login session id survives
  the login, and whether logging out actually revokes the token rather than just
  forgetting it.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts

  @password "test-only-password-4f2b9c1e"

  defp email, do: "browser-#{System.unique_integer([:positive])}@example.com"

  # The CSRF token appears twice (a meta tag and the form's hidden field) and is
  # new on every request, so it is not part of what the two pages say.
  defp normalise(html, address) do
    html
    |> String.replace(~r/name="csrf-token" content="[^"]*"/, ~s(name="csrf-token" content="-"))
    |> String.replace(~r/name="_csrf_token" value="[^"]*"/, ~s(name="_csrf_token" value="-"))
    |> String.replace(address, "-")
  end

  defp registered do
    e = email()
    {:ok, user} = Accounts.register_user(%{email: e, password: @password})
    {user, e}
  end

  describe "registration" do
    test "a new account is created and signed straight in", %{conn: conn} do
      e = email()
      conn = post(conn, ~p"/register", %{user: %{email: e, password: @password}})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email(e)
    end

    test "a duplicate address is refused and creates nothing", %{conn: conn} do
      {_user, e} = registered()

      conn = post(conn, ~p"/register", %{user: %{email: e, password: @password}})

      assert html_response(conn, 422) =~ "email"
      refute get_session(conn, :user_token)
    end

    test "the errors come back as sentences, not templates", %{conn: conn} do
      # Ecto carries its interpolations separately ("should be at least %{count}
      # character(s)"); a form that renders the raw message shows the placeholder.
      conn = post(conn, ~p"/register", %{user: %{email: email(), password: "short"}})

      body = html_response(conn, 422)
      assert body =~ "password"
      refute body =~ "%{"
    end

    test "a registration never lands on the :admin role", %{conn: conn} do
      e = email()
      post(conn, ~p"/register", %{user: %{email: e, password: @password, role: "admin"}})

      assert Accounts.get_user_by_email(e).role == :user
    end

    test "the password is never echoed back into the form", %{conn: conn} do
      conn = post(conn, ~p"/register", %{user: %{email: "not an email", password: @password}})

      refute html_response(conn, 422) =~ @password
    end
  end

  describe "login" do
    test "the wrong password gets the same page as an unknown address", %{conn: conn} do
      {_user, e} = registered()

      unknown_address = email()

      wrong = post(conn, ~p"/login", %{user: %{email: e, password: "nope-nope-nope"}})
      unknown = post(conn, ~p"/login", %{user: %{email: unknown_address, password: @password}})

      # Identical once the two things that legitimately differ are taken out: the
      # per-request CSRF token, and the address the form echoes back into its own
      # input (which the person typing already knows). A difference anywhere else
      # would tell an attacker which addresses exist.
      assert normalise(html_response(wrong, 401), e) ==
               normalise(html_response(unknown, 401), unknown_address)
    end

    test "a failed login issues no session at all", %{conn: conn} do
      {_user, e} = registered()

      conn = post(conn, ~p"/login", %{user: %{email: e, password: "nope-nope-nope"}})

      refute get_session(conn, :user_token)
      refute get_session(conn, :mfa_pending_user_id)
    end

    test "logging in replaces the pre-login session", %{conn: conn} do
      # Session fixation: an attacker who can plant a session cookie before login
      # must not still hold a valid one after it.
      {_user, e} = registered()

      planted = conn |> Plug.Test.init_test_session(%{}) |> put_session(:planted, "attacker")
      logged_in = post(planted, ~p"/login", %{user: %{email: e, password: @password}})

      assert get_session(logged_in, :user_token)
      refute get_session(logged_in, :planted)
    end

    test "the session token is opaque and is not the password or the address", %{conn: conn} do
      {_user, e} = registered()
      conn = post(conn, ~p"/login", %{user: %{email: e, password: @password}})

      token = get_session(conn, :user_token)
      refute token =~ e
      refute token =~ @password
      assert byte_size(token) >= 32
    end
  end

  describe "logout" do
    test "logging out revokes the token, not just the cookie", %{conn: conn} do
      {_user, e} = registered()
      signed_in = post(conn, ~p"/login", %{user: %{email: e, password: @password}})
      token = get_session(signed_in, :user_token)

      assert Accounts.get_user_by_session_token(token)

      out = delete(signed_in, ~p"/logout")
      assert redirected_to(out) == ~p"/login"
      refute get_session(out, :user_token)

      # The point: a copy of the cookie taken before logout is now worthless.
      refute Accounts.get_user_by_session_token(token)
    end

    test "logging out without a session is not an error", %{conn: conn} do
      assert redirected_to(delete(conn, ~p"/logout")) == ~p"/login"
    end

    test "one session's logout leaves the same user's other sessions alone" do
      # Signing out of a laptop must not sign the phone out too.
      {user, e} = registered()
      phone = Accounts.generate_user_session_token(user)

      laptop =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/login", %{user: %{email: e, password: @password}})

      delete(laptop, ~p"/logout")

      assert Accounts.get_user_by_session_token(phone)
    end
  end

  describe "the dashboard behind it" do
    test "an anonymous visitor is sent to /login and back afterwards", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_return_to) == "/"
    end

    test "a signed-in visitor is bounced off the login page", %{conn: conn} do
      {_user, e} = registered()
      signed_in = post(conn, ~p"/login", %{user: %{email: e, password: @password}})

      assert redirected_to(get(signed_in, ~p"/login")) == ~p"/"
    end
  end
end
