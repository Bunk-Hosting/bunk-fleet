defmodule ControlPlane.Fleet.PortPoolTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.PortForward
  alias ControlPlane.Fleet.PortPool
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_with_ports(region, attrs \\ %{}) do
    defaults = %{
      public_host: "node.example.test",
      public_port_start: 20_000,
      public_port_end: 20_004
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

  defp vps(region, node) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10
    })
    |> Repo.insert!()
  end

  describe "allocate/3" do
    test "hands out the first port in the node's range" do
      r = region()
      node = node_with_ports(r)

      assert {:ok, %PortForward{public_port: 20_000, target_port: 22, protocol: :tcp}} =
               PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
    end

    test "never hands out a port twice on the same node" do
      r = region()
      node = node_with_ports(r)

      ports =
        for _ <- 1..3 do
          {:ok, f} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
          f.public_port
        end

      assert ports == [20_000, 20_001, 20_002]
    end

    test "fills a hole left by a released forward" do
      r = region()
      node = node_with_ports(r)

      {:ok, first} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
      {:ok, _second} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
      Repo.delete!(first)

      assert {:ok, %PortForward{public_port: 20_000}} =
               PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
    end

    test "two nodes may each use the same port number" do
      # They are different public addresses. Treating the fleet as one port space
      # would exhaust it for everyone as soon as one node got busy.
      r = region()
      a = node_with_ports(r)
      b = node_with_ports(r)

      {:ok, on_a} = PortPool.allocate(Repo, a, %{vps_id: vps(r, a).id, target_port: 22})
      {:ok, on_b} = PortPool.allocate(Repo, b, %{vps_id: vps(r, b).id, target_port: 22})

      assert on_a.public_port == on_b.public_port
    end

    test "tcp and udp are separate spaces" do
      r = region()
      node = node_with_ports(r)

      {:ok, tcp} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})

      {:ok, udp} =
        PortPool.allocate(Repo, node, %{
          vps_id: vps(r, node).id,
          target_port: 51_820,
          protocol: :udp
        })

      assert tcp.public_port == udp.public_port
    end

    test "refuses rather than reusing when the range is full" do
      r = region()
      node = node_with_ports(r, %{public_port_start: 20_000, public_port_end: 20_001})

      {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
      {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})

      assert {:error, :port_pool_exhausted} =
               PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
    end

    test "a node that declared no range gets the defaults" do
      r = region()
      node = node_with_ports(r, %{public_port_start: nil, public_port_end: nil})

      assert {20_000, 29_999} = PortPool.range(node)

      assert {:ok, %PortForward{public_port: 20_000}} =
               PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
    end

    test "the database refuses a duplicate the allocator would never produce" do
      r = region()
      node = node_with_ports(r)
      {:ok, first} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})

      {:error, changeset} =
        %PortForward{}
        |> PortForward.changeset(%{
          vps_id: vps(r, node).id,
          node_id: node.id,
          public_port: first.public_port,
          target_port: 22
        })
        |> Repo.insert()

      assert changeset.errors[:node_id] || changeset.errors[:public_port]
    end
  end

  describe "for_node/2" do
    test "lists a node's forwards in port order" do
      r = region()
      node = node_with_ports(r)
      other = node_with_ports(r)

      {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 22})
      {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: vps(r, node).id, target_port: 80})
      {:ok, _} = PortPool.allocate(Repo, other, %{vps_id: vps(r, other).id, target_port: 22})

      forwards = PortPool.for_node(Repo, node.id)

      assert [20_000, 20_001] = Enum.map(forwards, & &1.public_port)
      assert Enum.all?(forwards, &(&1.node_id == node.id))
    end
  end

  describe "the node's declared range" do
    test "a backwards range is rejected rather than silently allocating nothing" do
      changeset =
        Node.changeset(%Node{}, %{
          name: "n",
          region_id: Ecto.UUID.generate(),
          public_port_start: 30_000,
          public_port_end: 20_000
        })

      refute changeset.valid?
    end

    test "privileged ports are refused" do
      # Forwarding below 1024 puts the operator's own SSH and web server in the
      # pool we hand out to customers.
      changeset =
        Node.changeset(%Node{}, %{
          name: "n",
          region_id: Ecto.UUID.generate(),
          public_port_start: 22,
          public_port_end: 1000
        })

      refute changeset.valid?
    end
  end
end
