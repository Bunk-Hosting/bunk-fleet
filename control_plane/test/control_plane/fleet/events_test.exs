defmodule ControlPlane.Fleet.EventsTest do
  # Pure PubSub, no database — safe to run async. The PubSub server
  # (ControlPlane.PubSub) is started by the application supervisor.
  use ExUnit.Case, async: true

  alias ControlPlane.Fleet.Events

  test "topic/0 returns the fleet changes topic" do
    assert Events.topic() == "fleet:changes"
  end

  test "a subscriber receives broadcast_changed events" do
    assert :ok = Events.subscribe()
    assert :ok = Events.broadcast_changed(:node)

    assert_receive {:fleet_changed, :node}
  end

  test "broadcast_changed/1 carries the given kind" do
    :ok = Events.subscribe()

    for kind <- [:node, :vps, :nodes_offline, :usage] do
      assert :ok = Events.broadcast_changed(kind)
      assert_receive {:fleet_changed, ^kind}
    end
  end

  test "a process that did not subscribe receives nothing" do
    assert :ok = Events.broadcast_changed(:vps)
    refute_receive {:fleet_changed, _kind}
  end

  test "broadcast_changed/1 always returns :ok (best-effort)" do
    assert :ok = Events.broadcast_changed(:usage)
  end
end
