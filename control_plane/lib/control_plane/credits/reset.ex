defmodule ControlPlane.Credits.Reset do
  @moduledoc """
  Zet alle tegoeden terug op nul.

  Wat er op de saldi stond kwam uit de testperiode: handmatige ophogingen uit het
  beheerpaneel van duizenden euro's, en opwaarderingen die met de testsleutel van
  Mollie op betaald zijn gezet. Daar heeft nooit geld in gezeten, en zolang het
  bleef staan kon er wel echte capaciteit mee besteld worden.

  Er wordt niets weggehaald. Het grootboek is de verantwoording en hoort alleen
  aan te groeien; een saldo dat verandert doordat oude regels verdwijnen valt
  niet meer na te rekenen. In plaats daarvan komt er per gebruiker één regel bij
  die het saldo precies op nul brengt, met in de omschrijving waarom.

  De logica staat hier en niet in de Mix-taak, omdat productie een release draait
  waar geen Mix in zit. Zo is hij van beide kanten aan te roepen:

      mix bunk.reset_credits --doen
      bin/control_plane eval 'ControlPlane.Release.reset_credits(doen: true)'
  """

  import Ecto.Query

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Repo

  @kind "correction"
  @description "Saldo teruggezet bij de overgang naar echte betalingen"

  @typedoc "Eén gebruiker met een saldo dat niet nul is."
  @type saldo :: %{user_id: Ecto.UUID.t(), email: String.t(), saldo: integer()}

  @doc """
  De saldi die niet op nul staan, grootste eerst.

  Het saldo is de som van het grootboek en geen kolom die wordt bijgehouden;
  daarom wordt het hier ook zo uitgerekend.
  """
  @spec plan() :: [saldo()]
  def plan do
    from(l in LedgerEntry,
      join: u in assoc(l, :user),
      group_by: [l.user_id, u.email],
      having: sum(l.amount_cents) != 0,
      order_by: [desc: sum(l.amount_cents)],
      select: %{user_id: l.user_id, email: u.email, saldo: sum(l.amount_cents)}
    )
    |> Repo.all()
  end

  @doc """
  Boekt per gebruiker de correctie die het saldo op nul brengt.

  Geeft de regels terug die zijn weggeboekt, zodat de aanroeper kan laten zien
  wat er gebeurd is in plaats van alleen dát er iets gebeurd is.
  """
  @spec apply!() :: [saldo()]
  def apply! do
    regels = plan()

    Enum.each(regels, fn %{user_id: user_id, saldo: saldo} ->
      {:ok, _} = Credits.add_entry(user_id, -saldo, @kind, @description)
    end)

    regels
  end

  @doc "Een bedrag in centen als leesbaar euroteken-loos bedrag."
  @spec euro(integer()) :: String.t()
  def euro(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2) <> " EUR"
end
