defmodule ControlPlane.Console.Tickets do
  @moduledoc """
  Single-use, short-lived tickets that authorize one browser console WebSocket.

  A browser can't send an `Authorization` header on a WebSocket handshake, and
  the bearer token lives in localStorage (not a cookie), so the bearer can't ride
  the WS connect. Instead the owner-checked REST endpoint mints a ticket bound to
  `{vps_id, user_id}`; the WS handshake redeems it exactly once. This is what
  proves identity + ownership at connect time, scoped to a single VPS — closing
  the "anyone who guesses a VPS id attaches to its root console" IDOR.

  The ETS table is owned by this GenServer (which also sweeps expired rows);
  mint/redeem hit ETS directly so they never bottleneck on the process.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Mint a single-use ticket for a VPS the caller owns."
  def mint(vps_id, user_id) do
    ticket = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {ticket, to_string(vps_id), user_id, expires})
    ticket
  end

  @doc "Redeem a ticket exactly once. {:ok, %{vps_id, user_id}} or :error."
  def redeem(ticket) when is_binary(ticket) and ticket != "" do
    case :ets.take(@table, ticket) do
      [{^ticket, vps_id, user_id, expires}] ->
        if System.monotonic_time(:millisecond) <= expires,
          do: {:ok, %{vps_id: vps_id, user_id: user_id}},
          else: :error

      _ ->
        :error
    end
  end

  def redeem(_), do: :error

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @ttl_ms)
end
