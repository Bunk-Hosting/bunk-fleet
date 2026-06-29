defmodule ControlPlaneWeb.ApiResponse do
  @moduledoc """
  Shared JSON error response for the API controllers — one home for the
  `put_status |> json(%{error: ...})` shape that was copy-pasted across them.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @doc ~S(Halts the response with `status` and a `{"error": msg}` body.)
  def error(conn, status, msg) do
    conn
    |> put_status(status)
    |> json(%{error: msg})
  end
end
