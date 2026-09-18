defmodule ControlPlane.MeldingRemTest do
  @moduledoc """
  Een toestand die blijft bestaan mag niet elke dertig seconden een mail sturen.

  Dit is geen theoretische netheid. Een vastgelopen agent-uitrol meldde zich bij
  elke reconcilertik, dat zijn twee mails per minuut, en daarmee was het
  dagquotum van de mailserver op een ochtend op. Daarna kwam er geen enkele
  melding meer door -- ook niet die over een betaling zonder tegoed.

  De rem zit in de Notifier en niet bij de aanroepers, zodat de volgende melding
  die iemand toevoegt hem vanzelf heeft.
  """
  use ExUnit.Case, async: false

  alias ControlPlane.Notifier
  alias ControlPlane.RateLimiter

  setup do
    RateLimiter.reset()
    eerder = Application.get_env(:control_plane, :ops_email)
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")

    on_exit(fn ->
      if eerder,
        do: Application.put_env(:control_plane, :ops_email, eerder),
        else: Application.delete_env(:control_plane, :ops_email)

      RateLimiter.reset()
    end)
  end

  test "dezelfde melding gaat hoogstens drie keer per uur de deur uit" do
    onderwerp = "Schijf zit vol #{System.unique_integer([:positive])}"

    for _ <- 1..3 do
      assert Notifier.deliver_operational_alert(onderwerp, "toestand") == :ok
    end

    assert Notifier.deliver_operational_alert(onderwerp, "toestand") == {:error, :throttled}
    assert Notifier.deliver_operational_alert(onderwerp, "toestand") == {:error, :throttled}
  end

  test "een ander onderwerp heeft zijn eigen emmer" do
    # Anders zou één luidruchtige toestand alle andere meldingen wegdrukken, en
    # dat is precies wat er misging: de vastgelopen uitrol maakte het quotum op
    # voor de melding over geld.
    een = "Uitrol staat stil #{System.unique_integer([:positive])}"
    twee = "Betaling zonder opwaardering #{System.unique_integer([:positive])}"

    for _ <- 1..3, do: Notifier.deliver_operational_alert(een, "x")
    assert Notifier.deliver_operational_alert(een, "x") == {:error, :throttled}

    assert Notifier.deliver_operational_alert(twee, "y") == :ok
  end

  test "zonder OPS_EMAIL is het een configuratiegat en geen rem" do
    Application.delete_env(:control_plane, :ops_email)

    assert Notifier.deliver_operational_alert("wat dan ook", "x") == {:error, :no_ops_email}
  end
end
