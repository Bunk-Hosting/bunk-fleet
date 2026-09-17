defmodule ControlPlane.CreditsDubbeleTerugbetalingTest do
  @moduledoc """
  Een mislukte bestelling mag één keer worden terugbetaald, niet twee keer.

  De afschrijving gebeurt vóór de VPS bestaat, dus de grootboekregel heeft even
  geen `vps_id`. Precies daarop jaagt `refund_orphan_charges/1`: een afschrijving
  zonder VPS die ouder is dan de gracetijd. Betaalt de bestelweg zelf al terug
  zonder de oorspronkelijke regel te merken, dan vindt de sweeper hem tien
  minuten later alsnog en betaalt nóg een keer.

  Dat is geen randgeval. Het treedt op bij een doodgewone `:no_capacity` -- de
  fout die deze week op productie voorbijkwam -- en het is op productie ook
  gebeurd: er stond meer terugbetaald dan er ooit was afgeschreven.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp saldo(user), do: Credits.balance_cents(user.id)

  defp afschrijving(user, cents) do
    {:ok, charge} = Credits.charge(user.id, cents, "vps_charge", "VPS test")
    charge
  end

  test "de bestelweg en de sweeper betalen samen één keer terug" do
    user = confirmed_user_fixture()
    begin = saldo(user)

    charge = afschrijving(user, 500)
    assert saldo(user) == begin - 500

    # De bestelweg betaalt terug omdat het plaatsen mislukte.
    assert {:ok, _} = Credits.refund_failed_charge(charge)
    assert saldo(user) == begin

    # En tien minuten later komt de sweeper langs. Die hoort niets meer te
    # vinden: zonder de markering betaalt hij hetzelfde bedrag nog een keer.
    assert Credits.refund_orphan_charges(0) == 0
    assert saldo(user) == begin
  end

  test "de sweeper betaalt zelf ook maar één keer, hoe vaak hij ook draait" do
    user = confirmed_user_fixture()
    begin = saldo(user)

    afschrijving(user, 700)
    assert saldo(user) == begin - 700

    assert Credits.refund_orphan_charges(0) == 1
    assert saldo(user) == begin

    assert Credits.refund_orphan_charges(0) == 0
    assert Credits.refund_orphan_charges(0) == 0
    assert saldo(user) == begin
  end

  test "de tegenboeking en de markering zijn één transactie" do
    # Vallen die uit elkaar -- een deploy tussen de twee writes -- dan staat er
    # een terugbetaling zonder markering, en betaalt elke volgende tik opnieuw
    # uit. Zonder bovengrens.
    user = confirmed_user_fixture()
    charge = afschrijving(user, 300)

    assert {:ok, _} = Credits.refund_failed_charge(charge)

    bijgewerkt = Repo.get!(LedgerEntry, charge.id)
    assert bijgewerkt.kind == "vps_charge_refunded"

    tegenboekingen =
      Repo.all(
        from e in LedgerEntry,
          where: e.user_id == ^user.id and e.kind == "vps_refund" and e.amount_cents > 0
      )

    assert length(tegenboekingen) == 1
  end

  test "een afschrijving die al is terugbetaald wordt niet nog eens terugbetaald" do
    user = confirmed_user_fixture()
    begin = saldo(user)
    charge = afschrijving(user, 250)

    assert {:ok, _} = Credits.refund_failed_charge(charge)
    assert {:ok, :already_refunded} = Credits.refund_failed_charge(charge)
    assert {:ok, :already_refunded} = Credits.refund_failed_charge(charge)

    assert saldo(user) == begin
  end

  test "een VPS die wel bestond wordt via zijn eigen weg terugbetaald, ook maar één keer" do
    user = confirmed_user_fixture()
    begin = saldo(user)

    {:ok, charge} = Credits.charge(user.id, 400, "vps_charge", "VPS test")
    # Een echte rij: op `ledger_entries.vps_id` staat een foreign key, dus een
    # verzonnen id zegt niets over het gedrag dat hier getest wordt.
    vps = vps_fixture(user)
    {:ok, _} = Credits.attach_vps(charge, vps.id)

    assert Credits.refund_charge_for_vps(vps.id)
    refute Credits.refund_charge_for_vps(vps.id)

    assert saldo(user) == begin
  end

  defp vps_fixture(user) do
    code = "r-#{System.unique_integer([:positive])}"

    region =
      %Region{}
      |> Region.changeset(%{code: code, name: "Regio"})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(%{owner_id: user.id})
    |> Repo.insert!()
  end
end
