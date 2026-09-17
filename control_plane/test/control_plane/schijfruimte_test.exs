defmodule ControlPlane.SchijfruimteTest do
  @moduledoc """
  Het uitlezen van `df`, want dat is het enige stuk dat stil fout kan gaan.

  Een verkeerd gelezen percentage is erger dan geen percentage: dan meldt de
  bewaking niets terwijl de schijf volloopt, of hij meldt elke dag iets terwijl
  er niets aan de hand is. Allebei eindigt ermee dat niemand er nog naar kijkt.
  """
  use ExUnit.Case, async: true

  alias ControlPlane.Schijfruimte

  test "leest het percentage uit gewone df-uitvoer" do
    uitvoer = """
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/sda1         20465580 17123456   2300000      88% /
    """

    assert Schijfruimte.lees(uitvoer) == {:ok, 88}
  end

  test "een pad met spaties in de naam gooit het niet in de war" do
    # De kolom die we willen is de vijfde, en de laatste kolom (het koppelpunt)
    # mag alles bevatten. Splitsen op spaties en het laatste veld pakken zou
    # hier fout gaan.
    uitvoer = """
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/sdb1          1024000   512000    512000      50% /mnt/mijn schijf
    """

    assert Schijfruimte.lees(uitvoer) == {:ok, 50}
  end

  test "onzin levert :onbekend op en geen exception" do
    # Een achtergrondronde mag niet omvallen omdat een commando iets onverwachts
    # zei. Geen meting is een acceptabele uitkomst; een gevallen reconciler niet.
    assert Schijfruimte.lees("") == :onbekend
    assert Schijfruimte.lees("df: /: No such file or directory") == :onbekend
    assert Schijfruimte.lees("kop\nzonder genoeg kolommen") == :onbekend
  end

  test "op deze machine is er gewoon een antwoord" do
    # De tegenproef bij de tests hierboven: ze zouden allemaal slagen als
    # `gebruikt_percentage/1` altijd :onbekend gaf.
    assert {:ok, pct} = Schijfruimte.gebruikt_percentage()
    assert pct >= 0 and pct <= 100
  end
end
