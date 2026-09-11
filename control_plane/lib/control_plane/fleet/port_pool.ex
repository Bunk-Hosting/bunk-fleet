defmodule ControlPlane.Fleet.PortPool do
  @moduledoc """
  Hands out public ports on a node, the way `IpPool` hands out addresses.

  A node's operator forwards a range to the node once; everything inside that
  range belongs to the fleet. Allocation is per node — two nodes may each use
  20001, because they are different public addresses — and is serialised by the
  caller's per-node advisory lock, with the `port_forwards` unique index as the
  database backstop.
  """
  import Ecto.Query

  alias ControlPlane.Fleet.{Node, PortForward}

  @default_start 20_000
  @default_end 29_999

  @doc """
  Allocates the lowest free public port on `node` and records the forward.

  Returns `{:ok, %PortForward{}}`, or `{:error, :port_pool_exhausted}` when the
  node's range is full — which is a capacity problem for the operator to widen,
  not something to paper over by reusing a port.
  """
  def allocate(repo, %Node{} = node, attrs) do
    %{vps_id: vps_id, target_port: target_port} = attrs
    protocol = Map.get(attrs, :protocol, :tcp)

    case next_free_port(repo, node, protocol) do
      {:ok, port} ->
        %PortForward{}
        |> PortForward.changeset(%{
          vps_id: vps_id,
          node_id: node.id,
          public_port: port,
          target_port: target_port,
          protocol: protocol,
          purpose: Map.get(attrs, :purpose)
        })
        |> repo.insert()

      {:error, _} = error ->
        error
    end
  end

  @doc "The forwards a node should currently be enforcing, oldest first."
  def for_node(repo, node_id) do
    repo.all(
      from f in PortForward,
        where: f.node_id == ^node_id,
        order_by: [asc: f.public_port],
        preload: [:vps]
    )
  end

  @doc "The port range `node` may allocate from, falling back to the defaults."
  def range(%Node{} = node) do
    {node.public_port_start || @default_start, node.public_port_end || @default_end}
  end

  defp next_free_port(repo, %Node{} = node, protocol) do
    {from, to} = range(node)

    if from > to do
      {:error, :port_pool_exhausted}
    else
      taken =
        repo.all(
          from f in PortForward,
            where: f.node_id == ^node.id and f.protocol == ^protocol,
            select: f.public_port
        )
        |> MapSet.new()

      case Enum.find(from..to, &(not MapSet.member?(taken, &1))) do
        nil -> {:error, :port_pool_exhausted}
        port -> {:ok, port}
      end
    end
  end
end
