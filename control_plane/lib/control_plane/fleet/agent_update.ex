defmodule ControlPlane.Fleet.AgentUpdate do
  @moduledoc """
  Vertelt elke online node na een uitrol dat er een nieuwe agent klaar kan staan.

  De control plane en de agent worden uit dezelfde boom gebouwd, dus een nieuwe
  control plane betekent bijna altijd ook een nieuwe agentbinary op
  `/dist/bunk-worker`. Zonder dit zou een node daar pas 's nachts achter komen,
  wanneer zijn eigen timer loopt.

  Het commando draagt geen versie. De node vergelijkt de gepubliceerde checksum
  met die van zijn eigen binary en doet niets als ze gelijk zijn. Daardoor is het
  blind rondsturen goedkoop: in het normale geval is het één HTTP-verzoek per
  node, en er is geen versiestring die scheef kan gaan staan en de node in een
  lus zou brengen.

  Nodes die offline zijn krijgen niets. Dat hoeft ook niet: hun eigen timer
  haalt de update op zodra ze terug zijn.
  """
  import Ecto.Query
  require Logger

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Repo

  @doc """
  Zet voor elke online node een `:update` klaar en geeft terug hoeveel dat er
  waren.

  Slaat nodes over die al een `:update` in de wacht hebben staan: twee keer
  dezelfde vraag stellen levert geen nieuwere binary op, en na een herstart van
  de control plane zou dat anders opstapelen.
  """
  @spec dispatch_to_online_nodes() :: non_neg_integer()
  def dispatch_to_online_nodes do
    nodes = Repo.all(from n in Node, where: n.status in [:online, :draining], select: n.id)
    openstaand = openstaande_node_ids()

    nodes
    |> Enum.reject(&(&1 in openstaand))
    |> Enum.reduce(0, fn node_id, aantal ->
      case Repo.insert(Command.changeset(%Command{}, %{node_id: node_id, kind: :update})) do
        {:ok, _} ->
          aantal + 1

        {:error, reason} ->
          Logger.warning("kon geen update klaarzetten voor node #{node_id}: #{inspect(reason)}")
          aantal
      end
    end)
  end

  defp openstaande_node_ids do
    Repo.all(
      from c in Command,
        where: c.kind == :update and c.status in [:pending, :delivered],
        select: c.node_id
    )
  end
end
