defmodule ControlPlaneWeb.PortForwardController do
  @moduledoc """
  The port forwards a node should currently be enforcing.

  Desired state, not events: the agent asks what the whole set should be and
  makes its firewall match. A node that was offline for a week, or whose rules
  were flushed by something else, converges on the next poll — which a stream of
  "add this forward" commands would not do.

  Authenticated as the node (`NodeAuth`), and scoped to it: an agent is told
  about its own VPSes and nothing else.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet.PortForward
  alias ControlPlane.Fleet.PortPool
  alias ControlPlane.Repo

  def index(conn, _params) do
    node = conn.assigns.current_node

    forwards =
      Repo
      |> PortPool.for_node(node.id)
      |> Enum.flat_map(&forward_json/1)

    json(conn, %{forwards: forwards})
  end

  # A forward whose VPS has no address yet, or is on its way out, is not
  # something to open a hole for. Dropped rather than sent with a null target,
  # which the agent would have to defend against anyway.
  defp forward_json(%PortForward{vps: %{ip_address: ip, status: status}} = forward)
       when is_binary(ip) do
    if status in [:deleted, :deleting] do
      []
    else
      [
        %{
          public_port: forward.public_port,
          target_ip: ip,
          target_port: forward.target_port,
          protocol: forward.protocol
        }
      ]
    end
  end

  defp forward_json(%PortForward{}), do: []
end
