defmodule ControlPlane.Console.Sessielog do
  @moduledoc """
  Legt vast wie wanneer op de terminal van welke VPS zat.

  Bunk heeft root op elke klant-VPS: het control plane zet bij de uitrol zijn
  eigen consolesleutel in de `authorized_keys`. Dat is niet weg te nemen zonder
  de webterminal weg te nemen. Wat wel kan, is het narekenbaar maken -- en
  daarom staat deze administratie ook in de uitdraai van een inzageverzoek. Een
  klant hoort te kunnen zien dat er niemand op zijn machine is geweest, in
  plaats van het te moeten geloven.

  Het wegschrijven mag nooit een sessie kunnen breken: een console die niet
  opengaat omdat de logregel niet lukt, ruilt een kleine tekortkoming in de
  administratie in voor een klant die niet bij zijn server kan. Vandaar dat
  `begin/3` bij een fout `nil` teruggeeft en alleen een waarschuwing logt.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Console.Sessielog.Regel
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @doc """
  Schrijft het begin van een sessie weg en geeft de id terug, of `nil`.

  `nil` betekent alleen dat er niets is vastgelegd; de sessie zelf gaat door.
  """
  @spec begin(binary() | nil, binary() | nil, DateTime.t()) :: binary() | nil
  def begin(user_id, vps_id, nu \\ Clock.now()) do
    %Regel{}
    |> Regel.changeset(%{
      user_id: user_id,
      vps_id: vps_id,
      door_beheerder: beheerder?(user_id, vps_id),
      started_at: nu
    })
    |> Repo.insert()
    |> case do
      {:ok, regel} ->
        regel.id

      {:error, reden} ->
        Logger.warning("consolesessie niet vastgelegd: #{inspect(reden)}")
        nil
    end
  rescue
    fout ->
      Logger.warning("consolesessie niet vastgelegd: #{inspect(fout)}")
      nil
  end

  @doc "Sluit een eerder begonnen sessie af. Een onbekende id is geen fout."
  @spec einde(binary() | nil, term(), DateTime.t()) :: :ok
  def einde(id, reden, nu \\ Clock.now())

  def einde(nil, _reden, _nu), do: :ok

  def einde(id, reden, nu) do
    from(r in Regel, where: r.id == ^id and is_nil(r.ended_at))
    |> Repo.update_all(set: [ended_at: nu, reden_einde: kort(reden), updated_at: nu])

    :ok
  rescue
    fout ->
      Logger.warning("einde van consolesessie niet vastgelegd: #{inspect(fout)}")
      :ok
  end

  @doc "De sessies op `vps_ids`, oudste eerst."
  @spec voor_vpsen([binary()]) :: [Regel.t()]
  def voor_vpsen([]), do: []

  def voor_vpsen(vps_ids) do
    Repo.all(from r in Regel, where: r.vps_id in ^vps_ids, order_by: r.started_at)
  end

  # Zat hier de eigenaar zelf, of iemand van Bunk? Kan de vraag niet beantwoord
  # worden (geen gebruiker, geen VPS, VPS al weg), dan is "nee" het veilige
  # antwoord: dit veld beschuldigt niemand op een aanname.
  defp beheerder?(nil, _vps_id), do: false
  defp beheerder?(_user_id, nil), do: false

  defp beheerder?(user_id, vps_id) do
    case Repo.one(from v in Vps, where: v.id == ^vps_id, select: v.owner_id) do
      nil -> false
      eigenaar -> eigenaar != user_id
    end
  end

  defp kort(reden) do
    reden |> inspect() |> String.slice(0, 200)
  end
end
