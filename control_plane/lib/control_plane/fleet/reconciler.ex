defmodule ControlPlane.Fleet.Reconciler do
  @moduledoc """
  Background reconciler that flips stale nodes to `:offline`.

  Nodes report heartbeats; a node whose agent dies keeps `status: :online` in the
  database forever (the heartbeat TTL only hides it from the scheduler), so the
  operator dashboard would keep showing a dead node as online. On a fixed
  interval this GenServer calls `ControlPlane.Fleet.mark_stale_nodes_offline/0`,
  which marks every `:online` node with a stale/absent heartbeat as `:offline`.

  Each tick also drives billing: after reconciling node health it meters every
  active VPS into `usage_records` (see `ControlPlane.Billing.meter_active_vpses/0`),
  which is how we account for the resource-hours our own nodes actually serve.

  ## Crash policy

  We deliberately wrap each tick in a `try/rescue`: a transient failure (e.g. a
  brief database blip) is logged and the next tick is rescheduled rather than
  crashing the process. This keeps reconciliation running through transient
  errors instead of relying on the supervisor to restart us — which, with a
  `:one_for_one` restart limit, could otherwise tear the process down for good
  after repeated failures.

  The node-reconcile and metering sub-steps are wrapped *independently* so that a
  failure in one does not skip the other (e.g. a metering blip must not stop dead
  nodes from being flipped offline).
  """
  use GenServer

  require Logger

  alias ControlPlane.Backups
  alias ControlPlane.Billing
  alias ControlPlane.Fleet
  alias ControlPlane.Provisioning
  alias ControlPlane.Subscriptions

  @default_interval_ms 30_000

  # Metering is time-delta based (each usage_records row stores the seconds since
  # that VPS's previous meter), so the cadence never changes the billed total — it
  # only bounds how fast usage_records grows and how often EVERY active VPS is
  # locked FOR UPDATE. Running it hourly instead of on every 30s tick cuts row
  # growth and lock churn ~120x at scale. Override with `:meter_interval_ms`.
  @default_meter_interval_ms 60 * 60 * 1000

  # Backups are dispatched from the same tick, gated the same way. Checking which
  # VPSes are due is one query; actually taking one is minutes of the node's disk,
  # and `Backups.run_due/1` only dispatches for VPSes whose last backup is older
  # than the configured interval — so this cadence bounds how often we ask, not
  # how often a customer's VPS is backed up. Override with `:backup_check_interval_ms`.
  @default_backup_check_interval_ms 15 * 60 * 1000

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
    meter_interval_ms = Keyword.get(opts, :meter_interval_ms, @default_meter_interval_ms)

    backup_check_interval_ms =
      Keyword.get(opts, :backup_check_interval_ms, @default_backup_check_interval_ms)

    schedule_tick(interval_ms)

    {:ok,
     %{
       interval_ms: interval_ms,
       meter_interval_ms: meter_interval_ms,
       last_meter_ms: nil,
       backup_check_interval_ms: backup_check_interval_ms,
       last_backup_check_ms: nil
     }}
  end

  @impl true
  def handle_info(:reconcile, %{interval_ms: interval_ms} = state) do
    # Each sub-step is isolated so a failure in one still lets the other run.
    reconcile_nodes()
    reclaim_reservations()
    fail_stuck_creates()
    retry_stuck_deletes()
    state = maybe_meter_usage(state)
    state = maybe_dispatch_backups(state)
    settle_subscriptions()
    schedule_tick(interval_ms)
    {:noreply, state}
  end

  # Meter only once per meter_interval_ms (default hourly), not every tick. Uses a
  # monotonic clock so it's immune to wall-clock jumps; the first tick after boot
  # meters immediately (last_meter_ms is nil), catching up any elapsed runtime.
  defp maybe_meter_usage(%{meter_interval_ms: mi, last_meter_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= mi do
      meter_usage()
      %{state | last_meter_ms: now}
    else
      state
    end
  end

  defp maybe_dispatch_backups(%{backup_check_interval_ms: bi, last_backup_check_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= bi do
      dispatch_backups()
      %{state | last_backup_check_ms: now}
    else
      state
    end
  end

  defp dispatch_backups do
    summary = Backups.run_due()

    if summary.started > 0 or summary.errors > 0 do
      Logger.info("backups dispatched", started: summary.started, errors: summary.errors)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler backup dispatch failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp reconcile_nodes do
    {count, _} = Fleet.mark_stale_nodes_offline()

    if count > 0 do
      Logger.info("fleet reconciler marked stale nodes offline", marked_offline: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler node tick failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp reclaim_reservations do
    count = Fleet.release_orphaned_reservations()

    if count > 0 do
      Logger.info("fleet reconciler reclaimed orphaned reservations", reclaimed: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler reservation reclaim failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp fail_stuck_creates do
    count = Provisioning.fail_stuck_queued_vpses()

    if count > 0 do
      # Loud, and to a person: each of these is a customer who was charged for a
      # VPS that was never created. The sweep can end the row's limbo; only
      # someone looking at the ledger can end theirs.
      Logger.error("failed #{count} vps(es) that were queued but never dispatched")

      ControlPlane.Notifier.deliver_operational_alert(
        "#{count} VPS(es) were charged for but never created",
        """
        #{count} VPS row(s) sat :queued past the grace period with no command
        behind them, which means the control plane stopped between persisting
        them and dispatching them. They have been marked :failed.

        The customer was charged before the create. The ledger records charges
        against a user rather than a VPS, so the refund cannot be made
        automatically — find the vps_charge entries near these VPSes' timestamps
        and reverse them.
        """
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler stuck-create sweep failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp retry_stuck_deletes do
    count = Provisioning.retry_stuck_deletes()

    if count > 0 do
      Logger.info("fleet reconciler retried failed teardowns", retried: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler delete-retry sweep failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp meter_usage do
    # Single-instance assumption: metering runs from this one reconciler process.
    # `Billing.meter_active_vpses/0` locks each VPS row FOR UPDATE so overlapping
    # ticks can't double-bill; running multiple control-plane instances would
    # additionally need leader election / an advisory lock around the tick. The
    # UNIQUE (vps_id, metered_at) index on usage_records is the data-layer backstop.
    count = Billing.meter_active_vpses()

    if count > 0 do
      Logger.info("fleet reconciler metered active vpses", metered: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler metering tick failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp settle_subscriptions do
    # Charge subscriptions that have come due and suspend/resume VPSes on the
    # customer's wallet balance. Cheap on an idle day: the due-query is
    # indexed and each due subscription advances its own date, so a subscription
    # is touched at most once per day regardless of the 30s tick.
    summary = Subscriptions.settle_due()

    if summary.charged > 0 or summary.suspended > 0 or summary.resumed > 0 do
      Logger.info(
        "recurring billing: charged=#{summary.charged} suspended=#{summary.suspended} " <>
          "resumed=#{summary.resumed} cancelled=#{summary.cancelled} errors=#{summary.errors}"
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler subscription settle failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :reconcile, interval_ms)
  end
end
