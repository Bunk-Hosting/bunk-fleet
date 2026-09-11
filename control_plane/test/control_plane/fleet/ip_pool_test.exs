defmodule ControlPlane.Fleet.IpPoolTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.IpPool
  alias ControlPlane.Fleet.{Region, Vps}

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp vps_with_ip(region, ip) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      ip_address: ip
    })
    |> Repo.insert!()
  end

  test "allocates the first free address with a Proxmox ip_config" do
    assert {:ok, %{ip: "10.10.0.20", config: "ip=10.10.0.20/19,gw=10.10.0.1"}} = IpPool.allocate()
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

  defp node_with_range(region) do
    %ControlPlane.Fleet.Node{}
    |> ControlPlane.Fleet.Node.changeset(%{
      name: "n-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vps_gateway: "192.168.50.1",
      vps_cidr_prefix: 24,
      vps_range_start: "192.168.50.10",
      vps_range_end: "192.168.50.20"
    })
    |> Repo.insert!()
  end

  test "allocates from the node's own range when it declared one" do
    node = node_with_range(region())

    assert {:ok, %{ip: "192.168.50.10", config: "ip=192.168.50.10/24,gw=192.168.50.1"}} =
             IpPool.allocate(node)
  end

  test "skips used addresses within the node's range" do
    r = region()
    node = node_with_range(r)
    vps_with_ip(r, "192.168.50.10")
    assert {:ok, %{ip: "192.168.50.11"}} = IpPool.allocate(node)
  end

  test "an address outside the node's range does not block it" do
    r = region()
    node = node_with_range(r)
    vps_with_ip(r, "10.10.0.20")
    assert {:ok, %{ip: "192.168.50.10"}} = IpPool.allocate(node)
  end

  test "nil node falls back to the global range" do
    assert {:ok, %{ip: "10.10.0.20"}} = IpPool.allocate(nil)
  end

  test "a live VPS IP is unique among live VPSes (DB backstop)" do
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
