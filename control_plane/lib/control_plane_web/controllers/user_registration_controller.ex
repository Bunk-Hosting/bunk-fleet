defmodule ControlPlaneWeb.UserRegistrationController do
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlaneWeb.UserAuth

  def new(conn, _params) do
    conn
    |> put_layout(html: false)
    |> render(:new, errors: [])
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Account aangemaakt. Welkom bij Bunk!")
        |> UserAuth.log_in_user(user)

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
              opts |> Keyword.get(String.to_existing_atom(k), k) |> to_string()
            end)
          end)
          |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)

        conn
        |> put_layout(html: false)
        |> put_status(:unprocessable_entity)
        |> render(:new, errors: errors)
    end
  end
end
