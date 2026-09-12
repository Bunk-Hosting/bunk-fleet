defmodule ControlPlane.Accounts.LoginThrottle do
  @moduledoc """
  Per-account throttling of failed password attempts.

  The IP rate limit in front of the login routes bounds how fast one client can
  guess. It does nothing about the shape credential stuffing actually takes: one
  password tried against one account from a thousand addresses, each of them well
  under the per-IP limit. This counts failures per *account* instead, so the limit
  follows the account being attacked rather than the machine attacking it.

  Deliberately not a hard lockout. A hard lockout hands anyone who knows an email
  address a way to keep its owner out of it; a window that widens as failures
  accumulate costs an attacker everything and costs a customer who fumbled their
  password about a minute. The delays are #{inspect([60, 300, 1800])} seconds
  after 5, 10 and 20 failures.

  A blocked attempt is reported to the caller as a wrong password and nothing
  else: a distinguishable "this account is throttled" is an oracle telling an
  attacker which addresses are real.

  Failures live in memory. A control-plane restart forgets them, which is the
  right trade — the alternative is a database write on every failed password, and
  an attacker who can restart the control plane has already won. The key is a
  SHA-256 of the address, so the table is useless to anyone who dumps it.
  """
  use GenServer

  @table :login_throttle
  @sweep_interval_ms 300_000
  # Rows untouched for this long are from an incident that is over.
  @stale_after_ms 3_600_000

  # {failures, seconds blocked once that many failures have accumulated}
  @steps [{20, 1800}, {10, 300}, {5, 60}]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Clears every counter. For test isolation: the table is a single global, so
  without a per-test reset one test's failed logins throttle the next.
  """
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  True while `email` is inside a throttling window from earlier failures.
  """
  def blocked?(email) do
    case :ets.lookup(@table, key(email)) do
      [{_key, _failures, blocked_until, _seen_at}] ->
        System.system_time(:millisecond) < blocked_until

      [] ->
        false
    end
  end

  @doc """
  Records one failed attempt for `email` and returns the number of failures now
  standing against it.
  """
  def note_failure(email) do
    now = System.system_time(:millisecond)
    k = key(email)

    failures = :ets.update_counter(@table, k, {2, 1}, {k, 0, 0, now})
    :ets.update_element(@table, k, [{3, now + delay_ms(failures)}, {4, now}])
    failures
  end

  @doc """
  Forgets every failure against `email`. Called on a successful login: the person
  who owns the account is not who the window was for.
  """
  def clear(email) do
    :ets.delete(@table, key(email))
    :ok
  end

  # Blocked until the newest step whose threshold this many failures has reached.
  # Below the first threshold there is no delay at all, so the customer who
  # mistypes once notices nothing.
  defp delay_ms(failures) do
    case Enum.find(@steps, fn {threshold, _seconds} -> failures >= threshold end) do
      {_threshold, seconds} -> seconds * 1000
      nil -> 0
    end
  end

  defp key(email), do: :crypto.hash(:sha256, String.downcase(email))

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
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
