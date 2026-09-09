defmodule ControlPlaneWeb.Admin.NodeController do
  @moduledoc """
  Operator/admin API for inspecting fleet nodes.

  Protected by `ControlPlaneWeb.Plugs.AdminAuth` (shared-secret admin token).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node

  def index(conn, _params) do
    nodes = Enum.map(Fleet.list_nodes(), &node_json/1)
    json(conn, %{nodes: nodes})
  end

  defp node_json(%Node{} = node) do
    %{
      id: node.id,
      name: node.name,
      region: region_code(node),
      status: node.status,
      hypervisor: node.hypervisor,
      total_vcpu: node.total_vcpu,
      total_ram_mb: node.total_ram_mb,
      total_disk_gb: node.total_disk_gb,
      available_vcpu: node.available_vcpu,
      available_ram_mb: node.available_ram_mb,
      available_disk_gb: node.available_disk_gb,
      last_heartbeat_at: node.last_heartbeat_at
    }
  end

  defp region_code(%Node{region: %{code: code}}), do: code
  defp region_code(%Node{}), do: nil
end
