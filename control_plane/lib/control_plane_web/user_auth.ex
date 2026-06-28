defmodule ControlPlaneWeb.UserAuth do
  @moduledoc """
  Browser session authentication for the customer portal: logs a user in/out via
  a signed session cookie holding a DB-backed session token, exposes
  `current_user` to plugs and LiveViews, and provides route guards.
  """
  use ControlPlaneWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias ControlPlane.Accounts

  @doc "Logs the user in: issues a session token, stores it, renews the session."
  def log_in_user(conn, user, _params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:" <> Base.url_encode64(token))
    |> redirect(to: return_to || signed_in_path())
  end

  @doc "Logs the user out and clears the session."
  def log_out_user(conn) do
    if token = get_session(conn, :user_token), do: Accounts.delete_user_session_token(token)

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  @doc "Plug: assigns `:current_user` from the session token (or nil)."
  def fetch_current_user(conn, _opts) do
    token = get_session(conn, :user_token)
    user = token && Accounts.get_user_by_session_token(token)
    assign(conn, :current_user, user)
  end

  @doc "Plug: requires an authenticated user, else redirects to /login."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Je moet ingelogd zijn om die pagina te bekijken.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc "Plug: bounces already-authenticated users away from auth pages."
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: signed_in_path()) |> halt()
    else
      conn
    end
  end

  # LiveView on_mount hooks.
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:current_path, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(socket, :save_current_path, :handle_params, fn _params, uri, socket ->
        {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Je moet ingelogd zijn.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_staff, _params, session, socket) do
    socket = mount_current_user(socket, session)
    user = socket.assigns.current_user

    if user && user.role in [:operator, :admin] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Geen toegang.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path())}
    else
      {:cont, socket}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.get_user_by_session_token(token)
    end)
  end

  defp maybe_store_return_to(%{method: "GET", request_path: path} = conn),
    do: put_session(conn, :user_return_to, path)

  defp maybe_store_return_to(conn), do: conn

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end

  defp signed_in_path, do: ~p"/app"
end
