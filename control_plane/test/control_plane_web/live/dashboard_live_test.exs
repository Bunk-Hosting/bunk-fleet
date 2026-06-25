defmodule ControlPlaneWeb.DashboardLiveTest do
  use ControlPlaneWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ControlPlane.Fleet

  setup do
    {:ok, region} = Fleet.create_region(%{code: "nl-1", name: "Netherlands 1"})

    {:ok, node} =
      Fleet.register_node(%{
        name: "node-a",
        region_id: region.id,
        status: :online,
        tier: :datacenter,
        hypervisor: :proxmox,
        total_vcpu: 32,
        total_ram_mb: 65_536,
        total_disk_gb: 1000,
        available_vcpu: 16,
        available_ram_mb: 32_768,
        available_disk_gb: 500,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{region: region, node: node}
  end

  test "mounts and renders the dashboard headers and node data", %{conn: conn, node: node} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Bunk Fleet"
    assert html =~ "Nodes"
    assert html =~ "VPSes"
    assert html =~ "Regions"
    assert html =~ node.name
    assert html =~ "nl-1"
  end

  test "is reachable at /dashboard too", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/dashboard")
    assert html =~ "Nodes"
  end
end
