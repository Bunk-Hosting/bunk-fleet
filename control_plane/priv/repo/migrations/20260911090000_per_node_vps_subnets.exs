defmodule ControlPlane.Repo.Migrations.PerNodeVpsSubnets do
  @moduledoc """
  Moves VPS addressing from one fleet-wide range to one block per node.

  Two things change together, and they have to:

    * the uniqueness rule. An address identifies a host *within a node's
      network*, so the same address on two nodes is not a conflict. The old
      fleet-wide index would have rejected the second node's first VPS.
    * every node that was silently sharing the default range now has a block of
      its own recorded, so `IpPool` hands out addresses that the node's own
      gateway can actually route.

  The backfill prefers the block a node's existing VPSes already sit in, so no
  live customer address is orphaned outside its node's declared range.
  """
  use Ecto.Migration

  alias ControlPlane.Fleet.Subnets
  alias ControlPlane.Net

  def up do
    drop index(:vpses, [:ip_address], name: :vpses_active_ip_uidx)

    # "Unplaced" is treated as one pseudo-node: two queued VPSes claiming the same
    # address is still a conflict, and once placed each is scoped to its own node.
    execute """
    CREATE UNIQUE INDEX vpses_active_node_ip_uidx
      ON vpses (COALESCE(node_id, '00000000-0000-0000-0000-000000000000'::uuid), ip_address)
      WHERE ip_address IS NOT NULL AND status <> 'deleted'
    """

    backfill_node_blocks()
  end

  def down do
    execute "DROP INDEX IF EXISTS vpses_active_node_ip_uidx"

    create unique_index(:vpses, [:ip_address],
             where: "ip_address IS NOT NULL AND status != 'deleted'",
             name: :vpses_active_ip_uidx
           )
  end

  # --- backfill --------------------------------------------------------------

  defp backfill_node_blocks do
    repo = repo()

    nodes =
      query!(repo, "SELECT id, vps_range_start FROM nodes ORDER BY inserted_at, id").rows

    taken =
      nodes
      |> Enum.flat_map(fn [_id, range_start] -> block_index(range_start) end)
      |> MapSet.new()

    {_taken, _} =
      Enum.reduce(nodes, {taken, repo}, fn
        [_id, range_start], acc when is_binary(range_start) -> acc
        [id, _nil], {taken, repo} -> assign_block(repo, id, taken)
      end)

    :ok
  end

  defp assign_block(repo, node_id, taken) do
    index = preferred_block(repo, node_id, taken) || lowest_free_block(taken)

    case index do
      nil ->
        # More pre-existing nodes than the supernet holds: leave the range NULL so
        # the node keeps falling back to the configured default rather than being
        # handed a block that overlaps someone else's.
        {taken, repo}

      index ->
        block = Subnets.block(index)

        query!(
          repo,
          """
          UPDATE nodes
             SET vps_gateway = $1, vps_cidr_prefix = $2,
                 vps_range_start = $3, vps_range_end = $4
           WHERE id = $5
          """,
          [
            block.vps_gateway,
            block.vps_cidr_prefix,
            block.vps_range_start,
            block.vps_range_end,
            Ecto.UUID.dump!(node_id)
          ]
        )

        {MapSet.put(taken, index), repo}
    end
  end

  # The block this node's own live VPSes already sit in, when it is still free.
  defp preferred_block(repo, node_id, taken) do
    query!(
      repo,
      """
      SELECT ip_address FROM vpses
       WHERE node_id = $1 AND ip_address IS NOT NULL AND status <> 'deleted'
      """,
      [Ecto.UUID.dump!(node_id)]
    ).rows
    |> Enum.flat_map(fn [ip] -> block_index(ip) end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp lowest_free_block(taken) do
    Enum.find(0..(Subnets.block_count() - 1), &(not MapSet.member?(taken, &1)))
  end

  defp block_index(address) when is_binary(address) do
    if Net.valid?(address) do
      # Re-derive from Subnets.block/1 rather than duplicating its arithmetic, so
      # a change to the carve can never drift from the backfill.
      Enum.filter(0..(Subnets.block_count() - 1), fn i ->
        block = Subnets.block(i)

        Net.to_int(address) >= Net.to_int(block.vps_gateway) and
          Net.to_int(address) <= Net.to_int(block.vps_range_end)
      end)
    else
      []
    end
  end

  defp block_index(_), do: []

  defp query!(repo, sql, params \\ []), do: repo.query!(sql, params, log: false)
end
