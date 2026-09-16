defmodule ControlPlane.MoneyTest do
  @moduledoc """
  De euro→cent-omzetting.

  Eén module, één functie, en toch de moeite waard: elke pakketprijs in de
  catalogus gaat hierdoorheen voordat er van een klant wordt afgeschreven. Een
  afrondingsregel die een halve cent de verkeerde kant op gooit is niet zichtbaar
  in de code maar wel op de rekening.
  """
  use ExUnit.Case, async: true

  alias ControlPlane.Money

  test "gewone catalogusprijzen komen exact uit" do
    for {euro, cent} <- [{"3.99", 399}, {"7.99", 799}, {"14.99", 1499}, {"29.99", 2999}] do
      assert Money.to_cents(Decimal.new(euro)) == cent
    end
  end

  test "hele euro's en nul" do
    assert Money.to_cents(Decimal.new("5")) == 500
    assert Money.to_cents(Decimal.new("0")) == 0
    assert Money.to_cents(Decimal.new("0.00")) == 0
  end

  test "een halve cent gaat omhoog, niet weg" do
    # Dit is de regel die de moduledoc belooft (round-half-up). Zou hij naar
    # beneden of naar even afronden, dan wijkt een prijs met drie decimalen af
    # van wat de klant op de site zag.
    assert Money.to_cents(Decimal.new("14.995")) == 1500
    assert Money.to_cents(Decimal.new("0.005")) == 1
    assert Money.to_cents(Decimal.new("0.004")) == 0
  end

  test "bedragen met meer decimalen worden niet afgekapt maar afgerond" do
    assert Money.to_cents(Decimal.new("1.006")) == 101
    assert Money.to_cents(Decimal.new("1.0049")) == 100
  end

  test "negatieve bedragen houden hun teken" do
    # Terugboekingen lopen langs dezelfde weg; een correctie die van teken
    # wisselt zou het grootboek stilzwijgend de verkeerde kant op duwen.
    assert Money.to_cents(Decimal.new("-3.99")) == -399
    assert Money.to_cents(Decimal.new("-0.005")) == -1
  end

  test "grote bedragen blijven exact (geen float onderweg)" do
    assert Money.to_cents(Decimal.new("99999.99")) == 9_999_999
    assert Money.to_cents(Decimal.new("0.07")) == 7
  end
end
