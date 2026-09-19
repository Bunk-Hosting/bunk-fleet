defmodule ControlPlane.FleetRegionaamTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet

  # De naam komt van de eigenaar van een node en wordt getoond aan klanten die
  # een VPS bestellen. Geen XSS-gat -- de schermen escapen -- maar wel tekst van
  # een semi-vertrouwde partij op een plek waar een vreemde hem leest.

  test "echte plaatsnamen komen erdoor, ook de lastige" do
    for naam <- ["Eindhoven", "Den Haag", "'s-Hertogenbosch", "Saint-Denis", "Z\u00fcrich", "A1"] do
      assert {:ok, _} = Fleet.ensure_region(naam), "#{naam} werd geweigerd"
    end
  end

  test "dezelfde plaats levert dezelfde regio op, hoe je hem ook typt" do
    assert {:ok, een} = Fleet.ensure_region("Maastricht")
    assert {:ok, twee} = Fleet.ensure_region("  maastricht  ")
    assert een.id == twee.id
  end

  test "wat geen plaatsnaam is komt er niet in" do
    for onzin <- [
          "<script>alert(1)</script>",
          "https://ergens.nl",
          "Eindhoven\u0000",
          "klik <b>hier</b>",
          "a",
          String.duplicate("x", 61)
        ] do
      assert {:error, :invalid_region} = Fleet.ensure_region(onzin),
             "#{inspect(onzin)} werd geaccepteerd als regionaam"
    end
  end
end
