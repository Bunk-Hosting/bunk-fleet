defmodule ControlPlaneWeb.Plugs.Bearer do
  @moduledoc """
  Shared `Authorization: Bearer <token>` handling for the auth plugs: extract a
  trimmed, non-empty token (an empty or whitespace-only token is never valid), and
  the common `401 {"error": "unauthorized"}` halt.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc "The trimmed, non-empty bearer token from the Authorization header, or `:error`."
  def token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case String.trim(token) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  @doc ~S(Halts the connection with 401 and a `{"error": "unauthorized"}` body.)
  def unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
