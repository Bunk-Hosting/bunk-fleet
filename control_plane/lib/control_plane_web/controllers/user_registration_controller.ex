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
        conn
        |> put_layout(html: false)
        |> put_status(:unprocessable_entity)
        |> render(:new, errors: error_messages(changeset))
    end
  end

  # Ecto's messages carry their interpolations separately ("should be at least
  # %{count} character(s)"); fill them in so the form shows a sentence rather than
  # a template.
  defp error_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  defp interpolate({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
