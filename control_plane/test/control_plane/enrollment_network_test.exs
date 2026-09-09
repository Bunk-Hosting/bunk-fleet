defmodule ControlPlane.EnrollmentNetworkTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.{Enrollment, Repo}
  alias ControlPlane.Fleet.{Region, Node}

  defp token(code) do
    region = %Region{} |> Region.changeset(%{code: code, name: "R"}) |> Repo.insert!()
    {:ok, {plaintext, _}} = Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: 3600})
    plaintext
  end

  test "enroll persists the worker's declared VPS network" do
    {:ok, %{node: node}} =
      Enrollment.enroll(token("nl-net1"), %{
        hypervisor: "proxmox",
        vps_network: %{gateway: "192.168.9.1", cidr_prefix: 24, range_start: "192.168.9.10", range_end: "192.168.9.50"}
      })

    node = Repo.get!(Node, node.id)
    assert node.vps_gateway == "192.168.9.1"
    assert node.vps_cidr_prefix == 24
    assert node.vps_range_start == "192.168.9.10"
    assert node.vps_range_end == "192.168.9.50"
  end

  test "enroll without a network leaves the range nil (global fallback)" do
    {:ok, %{node: node}} = Enrollment.enroll(token("nl-net2"), %{hypervisor: "proxmox"})
    assert is_nil(Repo.get!(Node, node.id).vps_range_start)
  end

  test "rejects an incomplete or invalid declared network" do
    alias ControlPlane.Fleet.Node
    base = %{name: "n", region_id: Ecto.UUID.generate()}

    # missing end/gateway/prefix
    refute Node.changeset(%Node{}, Map.put(base, :vps_range_start, "10.0.0.5")).valid?
    # invalid IP
    refute Node.changeset(%Node{}, Map.merge(base, %{vps_range_start: "nope", vps_range_end: "10.0.0.9", vps_gateway: "10.0.0.1", vps_cidr_prefix: 24})).valid?
    # reversed range
    refute Node.changeset(%Node{}, Map.merge(base, %{vps_range_start: "10.0.0.50", vps_range_end: "10.0.0.10", vps_gateway: "10.0.0.1", vps_cidr_prefix: 24})).valid?
    # complete + valid
    assert Node.changeset(%Node{}, Map.merge(base, %{vps_range_start: "10.0.0.10", vps_range_end: "10.0.0.50", vps_gateway: "10.0.0.1", vps_cidr_prefix: 24})).valid?
  end
end
