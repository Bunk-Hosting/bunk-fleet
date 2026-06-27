defmodule ControlPlaneWeb.CommandController do
  @moduledoc """
  Worker-node command API. Authentication is performed by
  `ControlPlaneWeb.Plugs.NodeAuth`, which assigns `conn.assigns.current_node`.

    * `GET /v1/commands` returns the calling node's deliverable commands as a JSON
      array `[{"id", "kind", "payload"}]`, marking each as delivered. This includes
      both never-delivered (`:pending`) commands and stale `:delivered` ones whose
      agent likely crashed before reporting a result, so they are redelivered.
      Redelivery assumes the agent handles commands idempotently (Go side). `[]`
      when none.
    * `POST /v1/commands/:id/result` accepts the agent's outcome for one of the
      node's commands and finalises the associated VPS, returning `204`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Repo
  alias ControlPlane.Provisioning
  alias ControlPlane.Fleet.Command

  def index(conn, _params) do
    node = conn.assigns.current_node

    commands =
      for command <- Provisioning.deliverable_commands_for_node(node) do
        {:ok, _delivered} = Provisioning.mark_delivered(command)

        %{
          "id" => command.id,
          "kind" => Atom.to_string(command.kind),
          "payload" => command.payload
        }
      end

    json(conn, commands)
  end

  def result(conn, %{"id" => id} = params) do
    node = conn.assigns.current_node

    # L1: validate the id is a UUID before querying — a malformed id would
    # otherwise raise Ecto.Query.CastError -> 500. A bad/unknown id collapses to
    # 404 (existence is never leaked).
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Command{} = command <- Repo.get_by(Command, id: id, node_id: node.id) do
      # apply_result is idempotent; a duplicate/already-applied result still
      # returns {:ok, _} so the agent gets a clean 204.
      case Provisioning.apply_result(command, result_attrs(params)) do
        {:ok, _command} ->
          send_resp(conn, :no_content, "")

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message(reason)})
      end
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  # L2: never to_string/1 an arbitrary error term (a failed-Multi changeset would
  # raise Protocol.UndefinedError -> 500). Only surface known atoms.
  defp error_message(reason) when is_atom(reason), do: to_string(reason)
  defp error_message(_reason), do: "unprocessable_entity"

  defp result_attrs(params) do
    %{
      "status" => params["status"],
      "vm_id" => params["vm_id"],
      "ip" => params["ip"],
      "error" => params["error"]
    }
  end
end
