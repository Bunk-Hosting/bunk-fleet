defmodule ControlPlane.ClockTest do
  @moduledoc """
  De ene plek die zegt wat "nu" is.

  Elke `utc_datetime`-kolom in dit schema bewaart hele seconden, en Ecto weigert
  een DateTime met microseconden in plaats van hem af te ronden. Dat is geen
  stijlkwestie maar wat een schrijfactie laat slagen, dus het hoort een test te
  hebben en geen aanname te zijn.
  """
  use ExUnit.Case, async: true

  alias ControlPlane.Clock

  test "now/0 heeft geen microseconden" do
    assert %DateTime{microsecond: {0, 0}} = Clock.now()
  end

  test "now/0 staat in UTC en dicht bij de echte tijd" do
    nu = Clock.now()
    assert nu.time_zone == "Etc/UTC"
    # Ruime marge: dit toetst dat de klok loopt, niet hoe snel de testmachine is.
    assert abs(DateTime.diff(DateTime.utc_now(), nu)) <= 2
  end

  test "shift/1 verschuift het aantal seconden, vooruit en achteruit" do
    nu = Clock.now()
    assert DateTime.diff(Clock.shift(60), nu) in 59..61
    assert DateTime.diff(Clock.shift(-60), nu) in -61..-59
  end

  test "shift/0-grens: nul verschuift niets" do
    assert DateTime.diff(Clock.shift(0), Clock.now()) in -1..1
  end

  test "shift/1 houdt de secondeprecisie vast" do
    # Zonder dit zou een verschoven tijdstip alsnog microseconden kunnen dragen
    # en een schrijfactie laten falen op precies het pad dat zelden loopt.
    assert %DateTime{microsecond: {0, 0}} = Clock.shift(3600)
    assert %DateTime{microsecond: {0, 0}} = Clock.shift(-3600)
  end
end
