defmodule ControlPlaneWeb.CommandController do
  @moduledoc """
  Handles `GET /v1/commands?node_id=...`: an authenticated node polls for pending
  commands. Authentication is performed by `ControlPlaneWeb.Plugs.NodeAuth`.

  For now this always returns an empty list; long-polling and real command dispatch
  arrive in a later iteration.
  """
  use ControlPlaneWeb, :controller

  def index(conn, _params) do
    json(conn, [])
  end
end
