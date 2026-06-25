defmodule ControlPlane.RateLimiter do
  @moduledoc """
  A small fixed-window rate limiter backed by a single public ETS table.

  `hit/3` records one request against `key` and reports whether the caller has
  exceeded `max` requests within the current `window_ms`-wide window. Counters are
  keyed by `{key, window}` where `window = system_time / window_ms`, so each window
  has its own counter and an old window's count never bleeds into the next.

  The GenServer owns the table and periodically sweeps counters from elapsed
  windows so memory stays bounded; the hot path (`hit/3`) is a lock-free
  `:ets.update_counter/4`, not a GenServer call, so it adds no serialization point.
  """
  use GenServer

  @table :rate_limiter
  @sweep_interval_ms 60_000
  # Counters created longer ago than this are from windows that can no longer be
  # current for any sane window size, so they're safe to sweep.
  @stale_after_ms 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records a hit for `key` in the current window and returns `:ok` if the caller is
  within `max`, or `{:error, :rate_limited}` once they exceed it.
  """
  def hit(key, max, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    # Atomically bump the count at position 2; seed a fresh row carrying the
    # creation time at position 3 (left untouched by later increments) for sweeping.
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, now})

    if count > max, do: {:error, :rate_limited}, else: :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:millisecond) - @stale_after_ms
    # Delete counters whose creation time (position 3) is older than the cutoff.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
