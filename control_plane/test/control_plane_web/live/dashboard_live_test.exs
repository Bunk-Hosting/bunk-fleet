defmodule ControlPlaneWeb.DashboardLiveTest do
  use ControlPlaneWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Events

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

  test "re-renders new node data when a fleet event is received", %{conn: conn, region: region} do
    {:ok, view, html} = live(conn, "/")

    # A node that does not exist at mount time...
    refute html =~ "node-late"

    {:ok, _node} =
      Fleet.register_node(%{
        name: "node-late",
        region_id: region.id,
        status: :online,
        tier: :datacenter,
        hypervisor: :proxmox,
        total_vcpu: 8,
        total_ram_mb: 16_384,
        total_disk_gb: 200,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # ...appears after the LiveView handles an event-driven reload. We drive the
    # PubSub message directly to the view's process so the test is deterministic
    # (no reliance on the 15s fallback timer).
    send(view.pid, {:fleet_changed, :node})

    assert render(view) =~ "node-late"
  end

  test "reloads when a change is broadcast via Events", %{conn: conn, region: region} do
    {:ok, view, _html} = live(conn, "/")

    {:ok, _node} =
      Fleet.register_node(%{
        name: "node-broadcast",
        region_id: region.id,
        status: :online,
        tier: :datacenter,
        hypervisor: :proxmox,
        total_vcpu: 4,
        total_ram_mb: 8_192,
        total_disk_gb: 100,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # The connected LiveView subscribed on mount, so a real broadcast reaches it.
    Events.broadcast_changed(:node)

    assert render(view) =~ "node-broadcast"
  end
end
