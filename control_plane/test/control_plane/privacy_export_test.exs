defmodule ControlPlane.PrivacyExportTest do
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Privacy.Export

  test "onbekend adres levert geen leeg document maar een duidelijke fout" do
    assert {:error, :not_found} = Export.verzamel("bestaat.niet@bunk.test")
  end

  test "hoofdletters in het adres maken niet uit" do
    u = confirmed_user_fixture("Inzage@bunk.test")
    assert {:ok, export} = Export.verzamel("  INZAGE@BUNK.TEST  ")
    assert export.account.id == u.id
  end

  test "het tegoed staat er met regels en een saldo dat klopt" do
    u = confirmed_user_fixture("inzage2@bunk.test")
    {:ok, _} = Credits.add_entry(u.id, 2_500, "topup", "Tegoed bijgeboekt (BUNK-9)")
    {:ok, _} = Credits.add_entry(u.id, -400, "vps_charge", "VPS Starter")

    assert {:ok, export} = Export.verzamel("inzage2@bunk.test")
    assert export.tegoed.saldo_centen == Credits.balance_cents(u.id)
    assert length(export.tegoed.regels) == 3
    assert Enum.any?(export.tegoed.regels, &(&1.soort == "vps_charge"))
  end

  # Dit is de test die er het meest toe doet. Een exportbestand gaat rondzwerven
  # -- per mail, in een downloadmap, in de back-up van iemands laptop. Er mag
  # dus geen sleutel in staan waarmee je het account kunt overnemen. Op de
  # ruwe JSON gecontroleerd en niet op de map, zodat een veld dat later ergens
  # diep in een tak wordt bijgezet er ook door wordt gevangen.
  test "er staat geen enkel geheim in de uitdraai" do
    u = confirmed_user_fixture("inzage3@bunk.test")

    assert {:ok, export} = Export.verzamel("inzage3@bunk.test")

    # De toelichting gaat er eerst af: daarin STAAT dat er geen wachtwoord in
    # zit, en die zin zou zichzelf laten afkeuren. Wat overblijft is alles wat
    # uit de database komt, en daar gaat deze controle over.
    json = export |> Map.delete(:export) |> Jason.encode!()

    assert json =~ "inzage3@bunk.test"
    assert export.export.toelichting =~ "staan hier bewust niet in"

    # Namen van velden die een sleutel dragen. Bewust niet "sessie" of "session":
    # er staat een tak `terminalsessies` in de uitdraai, en die hoort er juist te
    # zijn -- een klant moet kunnen zien wie er op zijn machine heeft gezeten. Wat
    # niet mag is een sessie*token*, en dat is een ander woord.
    for verboden <- ~w(hashed_password totp_secret secret token public_key
                       credential_id private_key authorized_keys) do
      refute String.contains?(String.downcase(json), verboden),
             "de export bevat #{verboden}"
    end

    # En de sleutels zelf, op waarde en niet op naam: een veld dat iemand later
    # toevoegt onder een naam die hierboven niet staat, wordt hier alsnog
    # gevangen.
    vers = ControlPlane.Repo.get!(ControlPlane.Accounts.User, u.id)
    refute json =~ vers.hashed_password
  end

  test "de uitdraai is geldige JSON en zegt wanneer hij gemaakt is" do
    confirmed_user_fixture("inzage4@bunk.test")
    assert {:ok, export} = Export.verzamel("inzage4@bunk.test")

    {:ok, terug} = export |> Jason.encode!() |> Jason.decode()
    assert {:ok, _, _} = DateTime.from_iso8601(terug["export"]["opgesteld_op"])
    assert terug["account"]["email"] == "inzage4@bunk.test"
    assert terug["vpsen"] == []
  end
end
