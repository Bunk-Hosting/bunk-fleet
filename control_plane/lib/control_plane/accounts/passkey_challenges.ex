defmodule ControlPlane.Accounts.PasskeyChallenges do
  @moduledoc """
  Kortstondige opslag van WebAuthn-challenges tussen de twee helften van een
  ceremonie.

  Registreren en inloggen met een passkey zijn allebei twee verzoeken: de server
  geeft een willekeurige challenge, de browser laat de authenticator die
  ondertekenen, en de server controleert het antwoord tegen precies die
  challenge. Tussen die twee verzoeken moet de challenge ergens staan. De API
  draait zonder sessie, dus dat is hier: in ETS, onder een willekeurig id dat de
  client terugstuurt.

  Een challenge is eenmalig — `take/1` haalt hem weg — en verloopt na vijf
  minuten. Een herstart van de control plane vergeet ze; wie midden in een
  ceremonie zat begint opnieuw, en dat is de juiste uitkomst.
  """
  use GenServer

  @table :passkey_challenges
  @ttl_ms 300_000
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Bewaart een challenge en geeft het id terug waarmee de client hem aanwijst."
  @spec put(term(), map()) :: String.t()
  def put(challenge, meta) when is_map(meta) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    expires_at = System.system_time(:millisecond) + @ttl_ms
    true = :ets.insert(@table, {id, challenge, meta, expires_at})
    id
  end

  @doc """
  Haalt een challenge op en verwijdert hem meteen: een tweede antwoord op
  dezelfde challenge is per definitie een replay.
  """
  @spec take(String.t()) :: {:ok, term(), map()} | :error
  def take(id) when is_binary(id) do
    case :ets.take(@table, id) do
      [{^id, challenge, meta, expires_at}] ->
        if System.system_time(:millisecond) < expires_at, do: {:ok, challenge, meta}, else: :error

      _ ->
        :error
    end
  end

  def take(_), do: :error

  @doc "Voor tests: alles vergeten."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
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
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
