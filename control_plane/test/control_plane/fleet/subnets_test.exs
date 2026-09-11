defmodule ControlPlane.Fleet.SubnetsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.{Node, Region, Subnets}
  alias ControlPlane.Net

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in_block(region, index) do
    block = Subnets.block(index)

    %Node{}
    |> Node.changeset(
      Map.merge(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id}, block)
    )
    |> Repo.insert!()
  end

  describe "block/1" do
    test "block 0 is the network the fleet already runs on" do
      assert %{
               vps_gateway: "10.10.0.1",
               vps_cidr_prefix: 22,
               vps_range_start: "10.10.0.20",
               vps_range_end: "10.10.3.254"
             } = Subnets.block(0)
    end

    test "each block starts where the previous one ends" do
      for index <- 0..(Subnets.block_count() - 2) do
        this = Subnets.block(index)
        next = Subnets.block(index + 1)

        assert Net.to_int(next.vps_gateway) - Net.to_int(this.vps_gateway) == 1024,
               "block #{index + 1} does not sit directly after block #{index}"

        assert Net.to_int(this.vps_range_end) < Net.to_int(next.vps_gateway),
               "block #{index} overlaps block #{index + 1}"
      end
    end

    test "the last block still fits inside the supernet" do
      last = Subnets.block(Subnets.block_count() - 1)
      assert last.vps_range_end == "10.10.255.254"
    end

    test "no block hands out its own gateway or the broadcast address" do
      for index <- [0, 1, Subnets.block_count() - 1] do
        block = Subnets.block(index)
        assert Net.to_int(block.vps_range_start) > Net.to_int(block.vps_gateway)
        assert rem(Net.to_int(block.vps_range_end), 256) == 254
      end
    end
  end

  describe "next_free_block/1" do
    test "hands out block 0 on an empty fleet" do
      assert {:ok, 0, %{vps_gateway: "10.10.0.1"}} = Subnets.next_free_block(Repo)
    end

    test "skips blocks already claimed by a node" do
      r = region()
      node_in_block(r, 0)
      node_in_block(r, 1)

      assert {:ok, 2, %{vps_gateway: "10.10.8.1"}} = Subnets.next_free_block(Repo)
    end

    test "fills a hole rather than always appending" do
      r = region()
      node_in_block(r, 0)
      node_in_block(r, 2)

      assert {:ok, 1, _block} = Subnets.next_free_block(Repo)
    end

    test "a node on its own network outside the supernet claims no block" do
      %Node{}
      |> Node.changeset(%{
        name: "byo-#{System.unique_integer([:positive])}",
        region_id: region().id,
        vps_gateway: "192.168.50.1",
        vps_cidr_prefix: 24,
        vps_range_start: "192.168.50.10",
        vps_range_end: "192.168.50.200"
      })
      |> Repo.insert!()

      assert {:ok, 0, _block} = Subnets.next_free_block(Repo)
    end
  end
end
