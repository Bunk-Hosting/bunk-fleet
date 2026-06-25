defmodule ControlPlane.Fleet.Reconciler do
  @moduledoc """
  Background reconciler that flips stale nodes to `:offline`.

  Nodes report heartbeats; a node whose agent dies keeps `status: :online` in the
  database forever (the heartbeat TTL only hides it from the scheduler), so the
  operator dashboard would keep showing a dead node as online. On a fixed
  interval this GenServer calls `ControlPlane.Fleet.mark_stale_nodes_offline/0`,
  which marks every `:online` node with a stale/absent heartbeat as `:offline`.

  ## Crash policy

  We deliberately wrap each tick in a `try/rescue`: a transient failure (e.g. a
  brief database blip) is logged and the next tick is rescheduled rather than
  crashing the process. This keeps reconciliation running through transient
  errors instead of relying on the supervisor to restart us — which, with a
  `:one_for_one` restart limit, could otherwise tear the process down for good
  after repeated failures.
  """
  use GenServer

  require Logger

  alias ControlPlane.Fleet

  @default_interval_ms 30_000

  @doc """
  Starts the reconciler.

  Options:

    * `:interval_ms` - milliseconds between reconciliation ticks
      (default `#{@default_interval_ms}`).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_tick(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:reconcile, %{interval_ms: interval_ms} = state) do
    reconcile()
    schedule_tick(interval_ms)
    {:noreply, state}
  end

  defp reconcile do
    {count, _} = Fleet.mark_stale_nodes_offline()

    if count > 0 do
      Logger.info("fleet reconciler marked stale nodes offline", marked_offline: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler tick failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :reconcile, interval_ms)
  end
end
