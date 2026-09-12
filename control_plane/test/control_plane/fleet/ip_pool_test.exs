defmodule ControlPlane.Fleet.IpPoolTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.IpPool
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_with_range(region, attrs \\ %{}) do
    defaults = %{
      vps_gateway: "192.168.50.1",
      vps_cidr_prefix: 24,
      vps_range_start: "192.168.50.10",
      vps_range_end: "192.168.50.20"
    }

    %Node{}
    |> Node.changeset(
      Map.merge(
        %{name: "n-#{System.unique_integer([:positive])}", region_id: region.id},
        Map.merge(defaults, attrs)
      )
    )
    |> Repo.insert!()
  end

  defp plain_node(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Repo.insert!()
  end

  defp vps_with_ip(region, ip, node \\ nil) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node && node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      ip_address: ip
    })
    |> Repo.insert!()
  end

  describe "the global fallback range" do
    test "allocates the first free address with a Proxmox ip_config" do
      assert {:ok, %{ip: "10.10.0.20", config: "ip=10.10.0.20/19,gw=10.10.0.1"}} =
               IpPool.allocate()
    end

    test "nil node falls back to the global range" do
      assert {:ok, %{ip: "10.10.0.20"}} = IpPool.allocate(nil)
    end

    test "skips addresses already held by non-deleted VPSes" do
      r = region()
      vps_with_ip(r, "10.10.0.20")
      vps_with_ip(r, "10.10.0.21")
      assert {:ok, %{ip: "10.10.0.22"}} = IpPool.allocate()
    end

    test "reuses an address freed by a :deleted VPS" do
      r = region()
      v = vps_with_ip(r, "10.10.0.20")
      {:ok, _} = v |> Vps.changeset(%{status: :deleted}) |> Repo.update()
      assert {:ok, %{ip: "10.10.0.20"}} = IpPool.allocate()
    end

    test "a node without a recorded range still uses the global default" do
      r = region()
      node = plain_node(r)

      assert {:ok, %{ip: "10.10.0.20", config: "ip=10.10.0.20/19,gw=10.10.0.1"}} =
               IpPool.allocate(node)
    end
  end

  describe "a node's own range" do
    test "allocates from the node's own range when it declared one" do
      node = node_with_range(region())

      assert {:ok, %{ip: "192.168.50.10", config: "ip=192.168.50.10/24,gw=192.168.50.1"}} =
               IpPool.allocate(node)
    end

    test "skips addresses used by a VPS on that same node" do
      r = region()
      node = node_with_range(r)
      vps_with_ip(r, "192.168.50.10", node)
      assert {:ok, %{ip: "192.168.50.11"}} = IpPool.allocate(node)
    end

    test "an address outside the node's range does not block it" do
      r = region()
      node = node_with_range(r)
      vps_with_ip(r, "10.10.0.20", node)
      assert {:ok, %{ip: "192.168.50.10"}} = IpPool.allocate(node)
    end

    test "exhausts only when the node's own range is full" do
      r = region()

      node =
        node_with_range(r, %{vps_range_start: "192.168.50.10", vps_range_end: "192.168.50.11"})

      vps_with_ip(r, "192.168.50.10", node)
      vps_with_ip(r, "192.168.50.11", node)

      assert {:error, :pool_exhausted} = IpPool.allocate(node)
    end
  end

  describe "isolation between nodes" do
    # The reason IpPool is node-scoped at all: each node runs its own layer-2 VPS
    # network, so the same address on two nodes is two different hosts. Before
    # this, one busy node ate the whole fleet's addresses.
    test "two nodes sharing a range do not consume each other's addresses" do
      r = region()
      a = node_with_range(r)
      b = node_with_range(r)

      vps_with_ip(r, "192.168.50.10", a)
      vps_with_ip(r, "192.168.50.11", a)

      assert {:ok, %{ip: "192.168.50.12"}} = IpPool.allocate(a)
      assert {:ok, %{ip: "192.168.50.10"}} = IpPool.allocate(b)
    end

    test "the same address on two different nodes is not a uniqueness conflict" do
      r = region()
      a = node_with_range(r)
      b = node_with_range(r)

      vps_with_ip(r, "192.168.50.10", a)
      assert %Vps{} = vps_with_ip(r, "192.168.50.10", b)
    end
  end

  describe "the database backstop" do
    test "two live VPSes on one node cannot share an address" do
      r = region()
      node = node_with_range(r)
      vps_with_ip(r, "192.168.50.10", node)

      {:error, cs} =
        %Vps{}
        |> Vps.changeset(%{
          name: "dup",
          region_id: r.id,
          node_id: node.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          ip_address: "192.168.50.10"
        })
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:ip_address]
    end

    test "two unplaced VPSes cannot share an address either" do
      r = region()
      vps_with_ip(r, "10.10.0.99")

      {:error, cs} =
        %Vps{}
        |> Vps.changeset(%{
          name: "dup",
          region_id: r.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          ip_address: "10.10.0.99"
        })
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:ip_address]
    end
  end
end
