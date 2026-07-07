defmodule ControlPlaneWeb.AuthController do
  @moduledoc """
  End-user/operator authentication API.

    * `POST   /api/v1/auth/register` — create a user, return it plus a session token.
    * `POST   /api/v1/auth/login`    — exchange email + password for a session token.
    * `GET    /api/v1/auth/me`       — (authenticated) the current user.
    * `DELETE /api/v1/auth/logout`   — (authenticated) revoke the presented session.

  Session tokens are returned as URL-safe Base64 (no padding) and expected back the
  same way in the `Authorization: Bearer <token>` header (see
  `ControlPlaneWeb.Plugs.ApiAuth`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlaneWeb.Plugs.Bearer

  # 7-day HttpOnly session cookie (matches the token's own lifetime).
  @session_cookie_max_age 60 * 60 * 24 * 7

  def register(conn, params) do
    # Verify the CAPTCHA server-side BEFORE creating an account (and granting the
    # signup bonus). Without this a bot skips the browser widget by calling the API
    # directly and farms free wallets. No-op until TURNSTILE_SECRET_KEY is set.
    with :ok <- ControlPlane.Turnstile.verify(params["turnstile_token"], client_ip(conn)),
         {:ok, user} <- Accounts.register_user(params) do
      token = Accounts.generate_user_session_token(user)

      conn
      |> put_session_cookie(token)
      |> put_status(:created)
      |> json(%{user: user_json(user), token: encode_token(token)})
    else
      {:error, reason} when reason in [:captcha_required, :captcha_failed, :captcha_unavailable] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "captcha_failed", turnstile_required: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  # Real client IP: Cloudflare sets CF-Connecting-IP; fall back to the peer.
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) and ip != "" -> ip
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  def login(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        # SECURITY: when 2FA is active, never issue a session token on password
        # alone — require a valid TOTP code (matches the browser MFA flow). The
        # client first calls without a code, gets {totp_required: true}, then
        # retries with the code.
        cond do
          not Accounts.totp_active?(user) ->
            issue_session(conn, user)

          is_binary(params["code"]) and Accounts.valid_totp?(user, params["code"]) ->
            issue_session(conn, user)

          is_binary(params["code"]) ->
            conn |> put_status(:unauthorized) |> json(%{totp_required: true, error: "invalid_code"})

          true ->
            conn |> put_status(:ok) |> json(%{totp_required: true})
        end

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid email or password"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end

  defp issue_session(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> put_session_cookie(token)
    |> put_status(:ok)
    |> json(%{user: user_json(user), token: encode_token(token)})
  end

  def me(conn, _params) do
    json(conn, %{user: user_json(conn.assigns.current_user)})
  end

  def logout(conn, _params) do
    # Extract from header OR the HttpOnly cookie so a cookie-based browser session
    # revokes the exact token it presented, then always clear the cookie.
    with {:ok, encoded} <- ControlPlaneWeb.Plugs.Bearer.session_token(conn),
         {:ok, token} <- Base.url_decode64(encoded, padding: false) do
      Accounts.delete_user_session_token(token)
    end

    conn
    |> delete_resp_cookie(Bearer.cookie_name(), path: "/")
    |> send_resp(:no_content, "")
  end

  @doc """
  Revokes every session of the authenticated user ("log out everywhere"), giving a
  kill switch for a leaked token without DB surgery.
  """
  def logout_all(conn, _params) do
    Accounts.delete_all_user_session_tokens(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end

  # --- helpers --------------------------------------------------------------

  defp encode_token(token), do: Base.url_encode64(token, padding: false)

  # Sets the session token as an HttpOnly cookie so the browser holds it out of
  # JS reach (an XSS foothold can't read it). Same-site Lax + Secure (over https)
  # for CSRF/transport safety. API clients keep using the returned bearer token.
  defp put_session_cookie(conn, token) do
    put_resp_cookie(conn, Bearer.cookie_name(), encode_token(token),
      http_only: true,
      secure: secure_request?(conn),
      same_site: "Lax",
      max_age: @session_cookie_max_age,
      path: "/"
    )
  end

  # True when the original client request was https — trust X-Forwarded-Proto from
  # the edge (the control plane itself is reached over http on the internal network).
  defp secure_request?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      ["https" | _] -> true
      _ -> conn.scheme == :https
    end
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      confirmed_at: user.confirmed_at,
      totp_enabled: not is_nil(user.totp_confirmed_at),
      inserted_at: user.inserted_at
    }
  end

  # --- TOTP (two-factor) — exposes bunk-fleet's own Accounts TOTP feature -----

  @doc "Starts TOTP setup: persists a fresh secret and returns it + a QR data URL."
  def totp_setup(conn, _params) do
    user = Accounts.start_totp_setup(conn.assigns.current_user)

    json(conn, %{
      secret: Accounts.totp_secret_base32(user),
      qr_data_url: qr_data_url(Accounts.totp_uri(user))
    })
  end

  @doc "Confirms TOTP setup with a code from the authenticator app."
  def totp_confirm(conn, %{"code" => code}) when is_binary(code) do
    case Accounts.confirm_totp(conn.assigns.current_user, code) do
      {:ok, _user} -> json(conn, %{detail: "ok"})
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})
    end
  end

  def totp_confirm(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "code is required"})

  @doc "Disables TOTP — requires a valid current code (defence in depth)."
  def totp_disable(conn, %{"code" => code}) when is_binary(code) do
    user = conn.assigns.current_user

    if Accounts.valid_totp?(user, code) do
      {:ok, _} = Accounts.disable_totp(user)
      json(conn, %{detail: "ok"})
    else
      conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})
    end
  end

  def totp_disable(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "code is required"})

  defp qr_data_url(uri) do
    svg = uri |> EQRCode.encode() |> EQRCode.svg(width: 200)
    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
