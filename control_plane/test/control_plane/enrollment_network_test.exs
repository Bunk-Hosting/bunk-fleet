defmodule ControlPlane.EnrollmentNetworkTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Subnets
  alias ControlPlane.Repo

  defp token(code) do
    region = %Region{} |> Region.changeset(%{code: code, name: "R"}) |> Repo.insert!()

    {:ok, {plaintext, _}} =
      Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: 3600})

    plaintext
  end

  test "enroll persists the worker's declared VPS network" do
    {:ok, %{node: node}} =
      Enrollment.enroll(token("nl-net1"), %{
        hypervisor: "proxmox",
        vps_network: %{
          gateway: "192.168.9.1",
          cidr_prefix: 24,
          range_start: "192.168.9.10",
          range_end: "192.168.9.50"
        }
      })

    node = Repo.get!(Node, node.id)
    assert node.vps_gateway == "192.168.9.1"
    assert node.vps_cidr_prefix == 24
    assert node.vps_range_start == "192.168.9.10"
    assert node.vps_range_end == "192.168.9.50"
  end

  test "enroll without a network is handed a block of its own" do
    {:ok, %{node: node}} = Enrollment.enroll(token("nl-net2"), %{hypervisor: "proxmox"})

    node = Repo.get!(Node, node.id)
    assert node.vps_gateway == "10.10.0.1"
    assert node.vps_cidr_prefix == 22
    assert node.vps_range_start == "10.10.0.20"
    assert node.vps_range_end == "10.10.3.254"
  end

  test "a second node gets a different block, not the first one's addresses" do
    {:ok, %{node: first}} = Enrollment.enroll(token("nl-net3"), %{hypervisor: "proxmox"})
    {:ok, %{node: second}} = Enrollment.enroll(token("nl-net4"), %{hypervisor: "proxmox"})

    first = Repo.get!(Node, first.id)
    second = Repo.get!(Node, second.id)

    assert first.vps_range_start == "10.10.0.20"
    assert second.vps_range_start == "10.10.4.20"
    # The ranges do not touch, so neither node can allocate into the other's.
    assert first.vps_range_end < second.vps_range_start
  end

  test "a declared network still wins over auto-assignment" do
    {:ok, %{node: node}} =
      Enrollment.enroll(token("nl-net5"), %{
        hypervisor: "proxmox",
        vps_network: %{
          gateway: "172.16.0.1",
          cidr_prefix: "24",
          range_start: "172.16.0.10",
          range_end: "172.16.0.200"
        }
      })

    node = Repo.get!(Node, node.id)
    assert node.vps_gateway == "172.16.0.1"
    # A prefix sent as a string is still a declaration, not a missing field.
    assert node.vps_cidr_prefix == 24
  end

  test "a half-declared network fails loudly instead of being silently overridden" do
    assert {:error, :invalid_token} =
             Enrollment.enroll(token("nl-net6"), %{
               hypervisor: "proxmox",
               vps_network: %{gateway: "172.16.0.1"}
             })
  end

  test "block assignment survives a node that brought its own network" do
    {:ok, %{node: byo}} =
      Enrollment.enroll(token("nl-net7"), %{
        hypervisor: "proxmox",
        vps_network: %{
          gateway: "172.16.0.1",
          cidr_prefix: 24,
          range_start: "172.16.0.10",
          range_end: "172.16.0.200"
        }
      })

    {:ok, %{node: auto}} = Enrollment.enroll(token("nl-net8"), %{hypervisor: "proxmox"})

    refute Repo.get!(Node, byo.id).vps_range_start == Subnets.block(0).vps_range_start
    assert Repo.get!(Node, auto.id).vps_range_start == Subnets.block(0).vps_range_start
  end

  test "rejects an incomplete or invalid declared network" do
    alias ControlPlane.Fleet.Node
    base = %{name: "n", region_id: Ecto.UUID.generate()}

    # missing end/gateway/prefix
    refute Node.changeset(%Node{}, Map.put(base, :vps_range_start, "10.0.0.5")).valid?
    # invalid IP
    refute Node.changeset(
             %Node{},
             Map.merge(base, %{
               vps_range_start: "nope",
               vps_range_end: "10.0.0.9",
               vps_gateway: "10.0.0.1",
               vps_cidr_prefix: 24
             })
           ).valid?

    # reversed range
    refute Node.changeset(
             %Node{},
             Map.merge(base, %{
               vps_range_start: "10.0.0.50",
               vps_range_end: "10.0.0.10",
               vps_gateway: "10.0.0.1",
               vps_cidr_prefix: 24
             })
           ).valid?

    # complete + valid
    assert Node.changeset(
             %Node{},
             Map.merge(base, %{
               vps_range_start: "10.0.0.10",
               vps_range_end: "10.0.0.50",
               vps_gateway: "10.0.0.1",
               vps_cidr_prefix: 24
             })
           ).valid?
  end
end
