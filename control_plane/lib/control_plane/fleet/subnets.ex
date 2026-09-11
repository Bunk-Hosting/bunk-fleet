defmodule ControlPlane.Fleet.Subnets do
  @moduledoc """
  Carves the fleet supernet into one private IPv4 block per node.

  Every node runs its own layer-2 VPS network on its own hardware: the hypervisor
  host holds the block's first address as the gateway, customer VPSes get the rest,
  and outbound traffic is NATed onto that node's own uplink. The blocks do not have
  to be globally unique for routing — they are separate broadcast domains — but
  making them unique anyway buys two things that matter:

    * the control plane can name a VPS by address without also naming its node,
      which keeps the console target unambiguous once a path to it exists;
    * an operator reading a log or a firewall rule can tell from the address alone
      which machine it is on.

  So the supernet is sliced deterministically and each node is handed the lowest
  free slice at enrollment. `#{inspect(__MODULE__)}` only computes and records
  blocks — the agent is what configures the bridge, forwarding and NAT on the node
  from the block it is handed back.

  A node whose agent declares its own network at enrollment keeps that network;
  auto-assignment is the fallback for the common case where it does not.
  """
  import Ecto.Query

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Net

  # 10.10.0.0/16 sliced into /22s: 64 nodes, 1022 addresses each. A node that
  # outgrows 1022 VPSes is a node that should have been two nodes.
  @supernet "10.10.0.0"
  @block_prefix 22
  @block_size 1024
  @block_count 64

  # .1 is the gateway on the node's bridge; .2-.19 are reserved for whatever else
  # the node needs to put on that network later (a second gateway, a load
  # balancer, an internal resolver) without renumbering customers.
  @first_host_offset 20
  @gateway_offset 1

  @doc "How many nodes the supernet can hold."
  def block_count, do: @block_count

  @doc "The CIDR prefix length of a single node block."
  def block_prefix, do: @block_prefix

  @doc """
  The network parameters for block `index`, as the `Node` fields that hold them.

  Block 0 is `10.10.0.0/22`: gateway `10.10.0.1`, customers from `10.10.0.20`
  through `10.10.3.254` (`.255` is the broadcast address).
  """
  def block(index) when index >= 0 and index < @block_count do
    base = Net.to_int(@supernet) + index * @block_size

    %{
      vps_gateway: Net.from_int(base + @gateway_offset),
      vps_cidr_prefix: @block_prefix,
      vps_range_start: Net.from_int(base + @first_host_offset),
      vps_range_end: Net.from_int(base + @block_size - 2)
    }
  end

  @doc """
  The lowest block not yet claimed by a node, or `{:error, :supernet_exhausted}`.

  Call this inside the enrollment transaction, after taking `lock/1` — two agents
  enrolling at the same instant would otherwise both read "block 3 is free".
  """
  def next_free_block(repo) do
    taken =
      repo.all(from n in Node, where: not is_nil(n.vps_range_start), select: n.vps_range_start)
      |> Enum.flat_map(&block_index/1)
      |> MapSet.new()

    case Enum.find(0..(@block_count - 1), &(not MapSet.member?(taken, &1))) do
      nil -> {:error, :supernet_exhausted}
      index -> {:ok, index, block(index)}
    end
  end

  @doc """
  Serialises block assignment for the calling transaction.

  A transaction-scoped advisory lock rather than row locks: the thing being
  claimed is the *absence* of a row, which has nothing to lock.
  """
  def lock(repo) do
    repo.query!("SELECT pg_advisory_xact_lock($1)", [:erlang.phash2({:fleet_subnets, @supernet})])
    :ok
  end

  # Which block an address falls in, as a single-element list so callers can
  # flat_map over a column that may hold an address outside the supernet (a node
  # that declared its own network) or something unparseable.
  defp block_index(address) when is_binary(address) do
    if Net.valid?(address) do
      offset = Net.to_int(address) - Net.to_int(@supernet)
      index = div(offset, @block_size)
      if offset >= 0 and index < @block_count, do: [index], else: []
    else
      []
    end
  end

  defp block_index(_), do: []
end
