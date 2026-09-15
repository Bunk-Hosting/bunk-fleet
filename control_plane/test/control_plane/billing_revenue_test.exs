defmodule ControlPlane.BillingRevenueTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Billing.Revenue
  alias ControlPlane.Credits
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Repo

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "test-only-password-4f2b9c1e"})
    u
  end

  defp paid_topup(user, cents, %Date{} = op) do
    {:ok, r} = Credits.create_topup_request(user.id, cents)
    {:ok, r} = Credits.mark_topup_paid(r.id)

    # De datum zetten we expliciet: een aangifte gaat over een periode, en een
    # test die alles op vandaag zet bewijst niets over de afbakening ervan.
    r
    |> Ecto.Changeset.change(paid_at: DateTime.new!(op, ~T[12:00:00], "Etc/UTC"))
    |> Repo.update!()
  end

  describe "btw uit een brutobedrag" do
    test "netto en btw tellen altijd op tot het brutobedrag" do
      # Als dit ooit een cent verliest, klopt de aangifte niet meer met de
      # rekening. Daarom over het hele bereik dat een topup kan hebben.
      for gross <- [500, 999, 1000, 1234, 2500, 3999, 7999, 10_000, 99_999, 100_000] do
        %{gross_cents: g, net_cents: n, vat_cents: v} = Revenue.split(gross)
        assert g == gross
        assert n + v == gross, "#{gross} valt uiteen in #{n} + #{v}"
      end
    end

    test "21% wordt uit een inclusief bedrag teruggerekend, niet erbovenop" do
      # 12,10 inclusief is 10,00 netto en 2,10 btw. Andersom rekenen zou
      # 12,10 + 2,54 opleveren en dus te veel afdragen.
      assert %{net_cents: 1000, vat_cents: 210} = Revenue.split(1210)
      assert Revenue.vat_percentage() == 21.0
    end

    test "nul blijft nul" do
      assert %{gross_cents: 0, net_cents: 0, vat_cents: 0} = Revenue.split(0)
    end
  end

  describe "totalen over een periode" do
    test "telt alleen betaalde topups, niet openstaande of geannuleerde" do
      u = user("rev1@bunk.test")
      paid_topup(u, 2500, ~D[2026-02-10])
      {:ok, _open} = Credits.create_topup_request(u.id, 5000)

      totals = Revenue.summary(~D[2026-01-01], ~D[2026-12-31])

      assert totals.payments == 1
      assert totals.gross_cents == 2500
      assert totals.net_cents + totals.vat_cents == 2500
    end

    test "de grenzen van de periode tellen volledig mee" do
      u = user("rev2@bunk.test")
      paid_topup(u, 1000, ~D[2026-04-01])
      paid_topup(u, 2000, ~D[2026-06-30])
      paid_topup(u, 4000, ~D[2026-07-01])

      kwartaal = Revenue.summary(~D[2026-04-01], ~D[2026-06-30])

      assert kwartaal.payments == 2
      assert kwartaal.gross_cents == 3000
    end

    test "weggegeven tegoed is geen omzet" do
      # Een signup_bonus is een grootboekregel zonder betaling erachter. Zou de
      # omzet aan het grootboek hangen in plaats van aan de topups, dan telde
      # die euro mee en zou er btw over afgedragen worden die niemand betaalde.
      u = user("rev3@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 1000, "signup_bonus", "welkom")

      assert %{payments: 0, gross_cents: 0, vat_cents: 0} =
               Revenue.summary(~D[2026-01-01], ~D[2026-12-31])
    end
  end

  describe "per kwartaal" do
    test "groepeert op het kwartaal waarin betaald is" do
      u = user("rev4@bunk.test")
      paid_topup(u, 1000, ~D[2026-02-15])
      paid_topup(u, 3000, ~D[2026-05-20])
      paid_topup(u, 2000, ~D[2026-05-21])

      assert [q1, q2] = Revenue.by_quarter(~D[2026-01-01], ~D[2026-12-31])

      assert q1.label == "2026 Q1"
      assert q1.payments == 1
      assert q1.gross_cents == 1000

      assert q2.label == "2026 Q2"
      assert q2.payments == 2
      assert q2.gross_cents == 5000
      assert q2.net_cents + q2.vat_cents == 5000
    end
  end

  describe "factuurregels" do
    test "één regel per betaling, met referentie en klant" do
      u = user("rev5@bunk.test")
      r = paid_topup(u, 2500, ~D[2026-03-03])

      assert [regel] = Revenue.invoices(~D[2026-03-01], ~D[2026-03-31])

      assert regel.reference == r.reference
      assert regel.customer == "rev5@bunk.test"
      assert regel.gross_cents == 2500
      assert regel.net_cents + regel.vat_cents == 2500
    end

    test "de som van de regels is gelijk aan het periodetotaal" do
      # Het overzicht en de onderliggende regels mogen nooit uit elkaar lopen:
      # dat is precies het verschil dat bij een controle wordt opgemerkt.
      u = user("rev6@bunk.test")

      for {cents, dag} <- [{999, ~D[2026-01-05]}, {2500, ~D[2026-02-05]}, {7999, ~D[2026-03-05]}] do
        paid_topup(u, cents, dag)
      end

      regels = Revenue.invoices(~D[2026-01-01], ~D[2026-03-31])
      totaal = Revenue.summary(~D[2026-01-01], ~D[2026-03-31])

      assert Enum.sum(Enum.map(regels, & &1.gross_cents)) == totaal.gross_cents
      assert Enum.sum(Enum.map(regels, & &1.vat_cents)) == totaal.vat_cents
      assert Enum.sum(Enum.map(regels, & &1.net_cents)) == totaal.net_cents

      # Deze drie bedragen (999, 2500, 7999) zijn niet willekeurig: per regel
      # afgerond geven ze 1995 cent btw, in één keer over het brutototaal 1996.
      # Zou het overzicht op die tweede manier rekenen, dan verschilt het van de
      # facturen waarop de btw daadwerkelijk in rekening is gebracht.
      assert totaal.vat_cents == 1995
    end
  end

  test "een lege periode geeft nullen terug in plaats van niets" do
    assert %{payments: 0, gross_cents: 0, net_cents: 0, vat_cents: 0} =
             Revenue.summary(~D[2020-01-01], ~D[2020-12-31])

    assert [] = Revenue.by_quarter(~D[2020-01-01], ~D[2020-12-31])
    assert [] = Revenue.invoices(~D[2020-01-01], ~D[2020-12-31])
  end

  test "de referentie is uniek, zodat hij als factuurnummer kan dienen" do
    u = user("rev7@bunk.test")
    a = paid_topup(u, 1000, ~D[2026-01-10])
    b = paid_topup(u, 1000, ~D[2026-01-11])

    assert a.reference != b.reference
    assert Repo.aggregate(TopupRequest, :count, :id) == 2
  end
end
