defmodule ControlPlane.Idempotency do
  @moduledoc """
  Zorgt dat een verzoek dat twee keer binnenkomt één keer wordt uitgevoerd.

  Het geval waar dit voor bestaat: een klant klikt op bestellen, de verbinding
  valt weg vlak voordat het antwoord terugkomt, en hij probeert het opnieuw. Het
  control plane ziet twee volwaardige verzoeken en maakt twee VPS'en aan met twee
  afschrijvingen. De klant merkt dat pas op zijn rekening.

  De sleutel komt van de client, want alleen die weet dat twee verzoeken
  dezelfde bedoeling hebben. Zonder sleutel gedraagt alles zich als voorheen --
  een oudere client of een curl-aanroep hoort niet te breken omdat wij iets
  hebben toegevoegd.

  ## Waarom de database en niet het geheugen

  Een uitrol tussen de twee verzoeken is precies het moment waarop dit gebeurt.
  Een ETS-tabel of de state van een proces is dan leeg, en de bescherming die je
  het hardst nodig had bestond net niet meer. De unieke index doet het werk: twee
  gelijktijdige verzoeken kunnen niet allebei dezelfde rij aanmaken.

  ## Drie uitkomsten

    * `{:ok, {:claimed, rij}}` -- dit verzoek mag het werk doen; geef `rij`
      later mee aan `finish/2` of `release/1`.
    * `{:ok, {:done, vps_id}}` -- ditzelfde verzoek is al gelukt; geef dat
      resultaat terug in plaats van het nog eens te doen.
    * `{:ok, :zonder_sleutel}` -- er was geen sleutel (of hij is intussen
      verdwenen); doe het werk zonder bescherming, zoals voorheen.
    * `{:error, :in_flight}` -- een eerder verzoek met deze sleutel is nog bezig.
      Niet opnieuw beginnen en ook geen resultaat verzinnen: de klant hoort te
      wachten.
  """
  import Ecto.Query

  alias ControlPlane.Idempotency.Key
  alias ControlPlane.Repo

  @scope_vps_create "vps_create"

  @doc "De scope voor het aanmaken van een VPS."
  def vps_create, do: @scope_vps_create

  @doc """
  Claimt `key` voor `user_id` binnen `scope`.

  Zie de moduledoc voor de drie uitkomsten.
  """
  @spec claim(binary(), String.t() | nil, String.t()) ::
          {:ok, {:claimed, Key.t()} | {:done, binary()} | :zonder_sleutel}
          | {:error, :in_flight}
  def claim(_user_id, nil, _scope), do: {:ok, :zonder_sleutel}
  def claim(_user_id, "", _scope), do: {:ok, :zonder_sleutel}

  def claim(user_id, key, scope) when is_binary(key) do
    %Key{}
    |> Key.changeset(%{user_id: user_id, key: String.slice(key, 0, 200), scope: scope})
    |> Repo.insert()
    |> case do
      {:ok, rij} ->
        {:ok, {:claimed, rij}}

      {:error, _changeset} ->
        # De unieke index sloeg toe: er is al een verzoek met deze sleutel.
        bestaande(user_id, key, scope)
    end
  end

  defp bestaande(user_id, key, scope) do
    case Repo.one(
           from k in Key,
             where: k.user_id == ^user_id and k.key == ^key and k.scope == ^scope
         ) do
      %Key{status: "done", vps_id: vps_id} when not is_nil(vps_id) -> {:ok, {:done, vps_id}}
      %Key{} -> {:error, :in_flight}
      # Weg tussen de insert en deze query: dan is er niets meer om op te
      # wachten en mag dit verzoek het gewoon doen.
      nil -> {:ok, :zonder_sleutel}
    end
  end

  @doc "Legt vast dat deze sleutel tot `vps_id` heeft geleid."
  @spec finish(Key.t(), binary()) :: :ok
  def finish(%Key{} = rij, vps_id) do
    rij |> Key.changeset(%{status: "done", vps_id: vps_id}) |> Repo.update()
    :ok
  end

  @doc """
  Geeft de sleutel weer vrij omdat het werk mislukte.

  Bewust vrijgeven en niet op "mislukt" zetten: de klant hoort het opnieuw te
  kunnen proberen, en met dezelfde sleutel. Een sleutel die na een mislukking
  blijft plakken zou een klant buitensluiten van zijn eigen bestelling.
  """
  @spec release(Key.t()) :: :ok
  def release(%Key{} = rij) do
    Repo.delete(rij)
    :ok
  end
end
