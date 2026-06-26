defmodule ControlPlaneWeb.UserSessionController do
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlaneWeb.UserAuth

  def new(conn, _params) do
    conn
    |> put_layout(html: false)
    |> render(:new, error: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        conn
        |> put_flash(:info, "Welkom terug!")
        |> UserAuth.log_in_user(user)

      nil ->
        conn
        |> put_layout(html: false)
        |> put_status(:unauthorized)
        |> render(:new, error: "Ongeldig e-mailadres of wachtwoord.")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Je bent uitgelogd.")
    |> UserAuth.log_out_user()
  end
end
