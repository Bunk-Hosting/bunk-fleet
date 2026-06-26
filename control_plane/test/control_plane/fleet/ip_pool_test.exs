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
    |> Vps.changeset(%{name: "v-#{System.unique_integer([:positive])}", region_id: region.id, vcpu: 1, ram_mb: 1024, disk_gb: 10, ip_address: ip})
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
end
