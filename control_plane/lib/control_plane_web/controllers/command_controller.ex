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

    case Repo.get_by(Command, id: id, node_id: node.id) do
      %Command{} = command ->
        # apply_result is idempotent; a duplicate/already-applied result still
        # returns {:ok, _} so the agent gets a clean 204.
        case Provisioning.apply_result(command, result_attrs(params)) do
          {:ok, _command} ->
            send_resp(conn, :no_content, "")

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: to_string(reason)})
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  defp result_attrs(params) do
    %{
      "status" => params["status"],
      "vm_id" => params["vm_id"],
      "ip" => params["ip"],
      "error" => params["error"]
    }
  end
end
