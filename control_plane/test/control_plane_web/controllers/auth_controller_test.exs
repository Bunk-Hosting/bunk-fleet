defmodule ControlPlaneWeb.AuthControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts

  @email "operator@example.com"
  @password "super-secret-pw-123"

  defp register_user(_) do
    {:ok, user} = Accounts.register_user(%{email: @email, password: @password, name: "Op"})
    %{user: user}
  end

  defp put_token(conn, token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  describe "POST /api/v1/auth/register" do
    test "creates a user and returns a token", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "email" => @email,
          "password" => @password,
          "name" => "Op"
        })

      assert %{"token" => token, "user" => user} = json_response(conn, 201)
      assert is_binary(token)
      assert user["email"] == @email
      assert user["role"] == "user"
      refute Map.has_key?(user, "hashed_password")
      refute Map.has_key?(user, "password")
    end

    test "returns 422 for a short password", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{"email" => @email, "password" => "short"})

      assert %{"errors" => %{"password" => [_ | _]}} = json_response(conn, 422)
    end
  end

  describe "POST /api/v1/auth/login" do
    setup [:register_user]

    test "returns a token for valid credentials", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => @password})
      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "returns 401 for a wrong password", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => "wrong-password-x"})

      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  describe "GET /api/v1/auth/me" do
    setup [:register_user]

    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/me")
      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns the current user with a token", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      conn = conn |> put_token(token) |> get(~p"/api/v1/auth/me")
      assert %{"user" => %{"id" => id, "email" => @email}} = json_response(conn, 200)
      assert id == user.id
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    setup [:register_user]

    test "revokes the session so subsequent requests are unauthorized", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      logout_conn = conn |> put_token(token) |> delete(~p"/api/v1/auth/logout")
      assert response(logout_conn, 204)

      me_conn = build_conn() |> put_token(token) |> get(~p"/api/v1/auth/me")
      assert json_response(me_conn, 401)
    end
  end

  describe "rate limiting" do
    # A dedicated X-Forwarded-For IP isolates this test's counter bucket from every
    # other test (which use the default 127.0.0.1), so the shared limiter can't
    # cause cross-test interference.
    defp hammer_login(ip) do
      build_conn()
      |> put_req_header("x-forwarded-for", ip)
      |> post(~p"/api/v1/auth/login", %{"email" => "nobody@example.com", "password" => "wrong-password-123"})
    end

    test "429s after too many auth attempts from one client" do
      ip = "203.0.113.7"
      # The configured limit is 30/min: the first 30 are served (401 wrong creds)...
      for _ <- 1..30, do: hammer_login(ip)
      # ...and the 31st is rejected with 429.
      assert %{"error" => "rate_limited"} = hammer_login(ip) |> json_response(429)
    end
  end

  describe "DELETE /api/v1/auth/logout/all" do
    setup [:register_user]

    test "revokes every session of the user", %{conn: conn, user: user} do
      t1 = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
      t2 = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      out = conn |> put_token(t1) |> delete(~p"/api/v1/auth/logout/all")
      assert response(out, 204)

      # Both the presenting token and the other live session are now invalid.
      assert build_conn() |> put_token(t1) |> get(~p"/api/v1/auth/me") |> json_response(401)
      assert build_conn() |> put_token(t2) |> get(~p"/api/v1/auth/me") |> json_response(401)
    end
  end
end
