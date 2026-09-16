defmodule ControlPlane.Billing.Revenue do
  @moduledoc """
  Omzet, btw en factuurregels voor de aangifte.

  ## Welk moment is belast

  Een klant koopt tegoed en verbruikt dat later. Dat zijn twee momenten, en maar
  één ervan is de belaste prestatie. Het tegoed is bij Bunk maar voor één ding
  in te wisselen — VPS-hosting, één btw-tarief — en daarmee een enkelvoudige
  voucher: die is belast op het moment van uitgifte, niet van inwisseling
  (art. 30a Wet OB). De omzet hangt hier dus aan de **betaalde topup**, niet aan
  de maandelijkse afschrijving.

  Dat is ook de enige keuze die klopt met wat er werkelijk aan geld binnenkomt.
  Een `signup_bonus` is tegoed dat wij weggeven; daar is niets voor betaald, dus
  het is geen omzet. Zou de aangifte aan het verbruik hangen, dan zou die
  weggegeven euro als omzet meetellen zodra de klant hem opmaakt.

  ## Wat niet meetelt

  Handmatig toegekend tegoed. Het beheerpaneel kan een saldo ophogen
  (`admin_topup`) of corrigeren (`admin_adjustment`); dat zijn grootboekregels
  zonder opwaarderingsverzoek en zonder betaling erachter. Ze verhogen wel wat
  een klant kan uitgeven, maar er is geen euro binnengekomen en er is dus ook
  geen btw over verschuldigd.

  ## Bedragen

  De catalogusprijzen zijn inclusief btw, dus het ontvangen bedrag is het
  brutobedrag. Netto en btw worden daaruit teruggerekend; het bruto blijft
  leidend zodat de som van de regels nooit een cent afwijkt van wat er op de
  rekening staat.
  """
  import Ecto.Query

  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Repo

  @vat_permille 210

  @doc "Het gehanteerde btw-tarief, als percentage."
  @spec vat_percentage() :: float()
  def vat_percentage, do: @vat_permille / 10

  @doc """
  Splitst een brutobedrag in netto en btw.

  Afgerond op hele centen, waarbij netto de afronding draagt: `netto + btw` komt
  daardoor altijd exact op het brutobedrag uit.
  """
  @spec split(integer()) :: %{gross_cents: integer(), net_cents: integer(), vat_cents: integer()}
  def split(gross_cents) when is_integer(gross_cents) do
    vat = round(gross_cents * @vat_permille / (1000 + @vat_permille))
    %{gross_cents: gross_cents, net_cents: gross_cents - vat, vat_cents: vat}
  end

  @doc """
  Totalen over een periode, op basis van de betaalde topups.

  `from` en `to` zijn data; `to` telt volledig mee.
  """
  @spec summary(Date.t(), Date.t()) :: map()
  def summary(%Date{} = from, %Date{} = to) do
    paid_topups(from, to)
    |> select([t], t.amount_cents)
    |> Repo.all()
    |> total()
    |> Map.merge(%{from: from, to: to})
  end

  # De btw wordt per betaling afgerond en daarna opgeteld, niet andersom.
  #
  # Dat is geen detail: rond je het brutototaal in één keer af, dan wijkt de
  # uitkomst een cent af van de som van de factuurregels — en de factuur is het
  # document waarop de btw daadwerkelijk in rekening is gebracht. Het overzicht
  # moet optellen tot wat er op de facturen staat, anders is het verschil precies
  # wat bij een controle wordt opgemerkt.
  defp total(bedragen) do
    Enum.reduce(bedragen, %{payments: 0, gross_cents: 0, net_cents: 0, vat_cents: 0}, fn cents,
                                                                                         acc ->
      regel = split(cents)

      %{
        payments: acc.payments + 1,
        gross_cents: acc.gross_cents + regel.gross_cents,
        net_cents: acc.net_cents + regel.net_cents,
        vat_cents: acc.vat_cents + regel.vat_cents
      }
    end)
  end

  @doc """
  Dezelfde totalen, per kalenderkwartaal — de eenheid waarin de btw-aangifte
  gedaan wordt.
  """
  @spec by_quarter(Date.t(), Date.t()) :: [map()]
  def by_quarter(%Date{} = from, %Date{} = to) do
    paid_topups(from, to)
    |> select([t], {t.paid_at, t.amount_cents})
    |> Repo.all()
    |> Enum.group_by(fn {paid_at, _} -> {paid_at.year, div(paid_at.month - 1, 3) + 1} end)
    |> Enum.sort()
    |> Enum.map(fn {{year, quarter}, rijen} ->
      rijen
      |> Enum.map(fn {_, cents} -> cents end)
      |> total()
      |> Map.merge(%{year: year, quarter: quarter, label: "#{year} Q#{quarter}"})
    end)
  end

  @doc """
  De factuurregels zelf: één per betaalde topup, nieuwste eerst.

  De referentie is het factuurnummer — die staat al op de topup en is uniek.
  """
  @spec invoices(Date.t(), Date.t()) :: [map()]
  def invoices(%Date{} = from, %Date{} = to) do
    paid_topups(from, to)
    |> join(:inner, [t], u in assoc(t, :user))
    |> order_by([t], desc: t.paid_at)
    |> select([t, u], %{
      reference: t.reference,
      paid_at: t.paid_at,
      customer: u.email,
      amount_cents: t.amount_cents,
      mollie_payment_id: t.mollie_payment_id
    })
    |> Repo.all()
    |> Enum.map(fn row -> Map.merge(row, split(row.amount_cents)) end)
  end

  # Alleen wat daadwerkelijk betaald is, en op de datum waarop het betaald werd —
  # niet de datum waarop de klant op "opwaarderen" klikte. Een openstaande of
  # geannuleerde topup is geen omzet.
  #
  # `mollie_payment_id` is de harde grens tussen omzet en de rest: het bestaat
  # alleen als er bij de betaalprovider werkelijk een betaling is aangemaakt.
  # Handmatig toegekend tegoed uit het beheerpaneel komt hier sowieso niet
  # langs — dat schrijft een grootboekregel (`admin_topup`, `admin_adjustment`)
  # en géén opwaarderingsverzoek — maar zonder deze eis zou één nieuwe knop die
  # wél een verzoek aanmaakt stilzwijgend in de btw-aangifte belanden. Er wordt
  # aangifte gedaan op dit getal; het moet niet kloppen bij toeval maar bij
  # constructie.
  defp paid_topups(from, to) do
    start = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    stop = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")

    from(t in TopupRequest,
      where:
        t.status == :paid and not is_nil(t.paid_at) and not is_nil(t.mollie_payment_id) and
          t.paid_at >= ^start and t.paid_at < ^stop
    )
  end
end
