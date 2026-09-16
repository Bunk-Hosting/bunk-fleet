defmodule ControlPlane.Fleet.AgentUpdate do
  @moduledoc """
  Rolt een nieuwe agentbinary uit over de fleet, in golven.

  De control plane en de agent worden uit dezelfde boom gebouwd, dus een nieuwe
  control plane betekent bijna altijd ook een nieuwe binary op
  `/dist/bunk-worker`. Zonder dit zou een node daar pas 's nachts achter komen,
  wanneer zijn eigen timer loopt.

  ## Waarom niet alles tegelijk

  De eerste versie stuurde het commando bij het opstarten naar elke online node
  in dezelfde seconde. Met één node valt dat niet op; met vier neemt een build
  die niet opstart de hele fleet in één keer mee. De updater op de node rolt wel
  terug als de service niet opkomt, maar dat is herstel achteraf.

  Nu gaat de eerste node alleen: een kanarie. Pas als die zich met de nieuwe
  versie terugmeldt — de agent rapporteert zijn build in de heartbeat — volgt de
  rest, in groepen van #{2}. Blijft de kanarie weg, dan stopt de uitrol en blijft
  de rest op de oude binary staan in plaats van er achteraan te vallen.

  ## Waar "klaar" aan afgelezen wordt

  Aan `nodes.agent_version` tegenover de build van deze control plane. Het
  commando zelf draagt geen versie: de node vergelijkt de gepubliceerde checksum
  met die van zijn eigen binary en doet niets als ze gelijk zijn. Daardoor is het
  blind versturen goedkoop en kan een herhaling geen kwaad.

  Kent de control plane zijn eigen build niet (geen versiestempel, bijvoorbeeld
  bij een handmatige build), dan is er niets om tegen af te lezen en doet dit
  niets. De nachtelijke timer op elke node blijft dan het vangnet.
  """
  import Ecto.Query
  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Notifier
  alias ControlPlane.Repo

  # De kanarie gaat alleen; daarna twee tegelijk. Klein genoeg dat een slechte
  # build nooit meer dan een paar nodes tegelijk raakt, groot genoeg dat een
  # fleet van tien niet tien tikken lang bezig is.
  @canary_size 1
  @wave_size 2

  # Hoe lang een node mag doen over een update voordat we hem als vastgelopen
  # beschouwen. Ophalen en herstarten is een kwestie van seconden; een kwartier
  # is ruim genoeg voor een trage schijf en kort genoeg om niet een halve dag
  # stil te staan.
  @stall_after_seconds 900

  @doc """
  Zet de volgende golf klaar, of wacht. Bedoeld om elke reconciler-tik aan te
  roepen; hij doet alleen iets als er iets te doen is.

  Geeft terug wat er gebeurde, zodat de aanroeper het kan loggen:
  `{:dispatched, n}`, `:waiting`, `:up_to_date`, `:stalled` of `:no_target`.
  """
  @spec dispatch_wave() ::
          {:dispatched, pos_integer()} | :waiting | :up_to_date | :stalled | :no_target
  def dispatch_wave do
    case target_version() do
      nil -> :no_target
      doel -> dispatch_wave(doel)
    end
  end

  defp dispatch_wave(doel) do
    lopend = in_flight()

    cond do
      lopend != [] and Enum.any?(lopend, &stalled?/1) ->
        melden_vastgelopen(lopend, doel)
        :stalled

      lopend != [] ->
        :waiting

      true ->
        achter = behind(doel)
        if achter == [], do: :up_to_date, else: verstuur(achter, doel)
    end
  end

  defp verstuur(achter, doel) do
    # Heeft nog geen enkele node de nieuwe build, dan is deze de kanarie en gaat
    # hij alleen. Zodra er één draait is bewezen dat de binary opstart en mag de
    # rest in groepen volgen.
    grootte = if any_on_target?(doel), do: @wave_size, else: @canary_size

    aantal =
      achter
      |> Enum.take(grootte)
      |> Enum.reduce(0, fn node_id, n ->
        case Repo.insert(Command.changeset(%Command{}, %{node_id: node_id, kind: :update})) do
          {:ok, _} ->
            n + 1

          {:error, reden} ->
            Logger.warning("kon geen update klaarzetten voor node #{node_id}: #{inspect(reden)}")
            n
        end
      end)

    if aantal > 0, do: {:dispatched, aantal}, else: :waiting
  end

  # Online nodes die de doelversie nog niet draaien, oudste heartbeat eerst zodat
  # de volgorde over tikken heen stabiel is.
  defp behind(doel) do
    Repo.all(
      from n in Node,
        where: n.status in [:online, :draining],
        where: is_nil(n.agent_version) or n.agent_version != ^doel,
        order_by: [asc: n.inserted_at],
        select: n.id
    )
  end

  defp any_on_target?(doel) do
    Repo.exists?(from n in Node, where: n.agent_version == ^doel)
  end

  defp in_flight do
    Repo.all(
      from c in Command,
        where: c.kind == :update and c.status in [:pending, :delivered],
        select: %{id: c.id, node_id: c.node_id, inserted_at: c.inserted_at}
    )
  end

  defp stalled?(%{inserted_at: at}) do
    DateTime.compare(at, Clock.shift(-@stall_after_seconds)) == :lt
  end

  # Een vastgelopen update stopt de uitrol: de rest van de fleet blijft op de
  # oude binary. Dat is het hele punt van een kanarie, maar het moet wel gemeld
  # worden — anders staat de fleet stil op iets wat niemand ziet.
  defp melden_vastgelopen(lopend, doel) do
    ids = Enum.map_join(lopend, ", ", & &1.node_id)

    Logger.error(
      "agent-uitrol naar #{doel} staat stil: node(s) #{ids} melden zich niet terug; " <>
        "de rest van de fleet blijft op de oude binary"
    )

    Notifier.deliver_operational_alert(
      "Agent-uitrol staat stil",
      "De uitrol naar #{doel} wacht al langer dan #{div(@stall_after_seconds, 60)} minuten op " <>
        "node(s) #{ids}. De overige nodes zijn bewust niet bijgewerkt. Controleer de agentlogs " <>
        "op die node(s); de nachtelijke timer probeert het daar vanzelf opnieuw."
    )
  end

  @doc """
  De build waar deze control plane uit komt, en dus de versie die elke agent moet
  draaien. `nil` wanneer er geen versiestempel is meegegeven.
  """
  @spec target_version() :: String.t() | nil
  def target_version do
    case Application.get_env(:control_plane, :build_version) do
      v when is_binary(v) and v != "" and v != "onbekend" -> v
      _ -> nil
    end
  end
end
