defmodule ControlPlaneWeb.Plugs.RateLimitPerGebruikerTest do
  @moduledoc """
  Achter de inlog telt de rem per gebruiker, niet per IP-adres.

  Waarom dat verschil ertoe doet: een emmer per IP zet twee klanten achter
  hetzelfde kantoornetwerk in hetzelfde hokje -- de een duwt de ander eruit --
  terwijl iemand die het er juist om doet gewoon van netwerk wisselt en een
  verse emmer krijgt. Het IP is dus streng voor de verkeerde en soepel voor de
  ander. Wie is ingelogd heeft een identiteit die niet meewisselt.
  """
  use ControlPlaneWeb.ConnCase, async: false

  alias ControlPlaneWeb.Plugs.RateLimit

  defp plug(opts), do: RateLimit.init(opts)

  defp met_gebruiker(id) do
    build_conn() |> Plug.Conn.assign(:current_user, %{id: id})
  end

  setup do
    ControlPlane.RateLimiter.reset()
    :ok
  end

  test "twee gebruikers vanaf hetzelfde adres hebben elk hun eigen emmer" do
    opts =
      plug(
        bucket: "t-#{System.unique_integer([:positive])}",
        max: 2,
        window_ms: 60_000,
        by: :user
      )

    # Gebruiker A maakt zijn emmer leeg.
    assert %{halted: false} = RateLimit.call(met_gebruiker("a"), opts)
    assert %{halted: false} = RateLimit.call(met_gebruiker("a"), opts)
    assert %{halted: true} = RateLimit.call(met_gebruiker("a"), opts)

    # B komt van hetzelfde adres (in de test 127.0.0.1) en merkt daar niets van.
    assert %{halted: false} = RateLimit.call(met_gebruiker("b"), opts)
  end

  test "zonder ingelogde gebruiker valt hij terug op het adres" do
    # Anders zou je de rem omzeilen door je token weg te laten.
    opts =
      plug(
        bucket: "t-#{System.unique_integer([:positive])}",
        max: 1,
        window_ms: 60_000,
        by: :user
      )

    assert %{halted: false} = RateLimit.call(build_conn(), opts)
    assert %{halted: true} = RateLimit.call(build_conn(), opts)
  end

  test "de geknepen aanroep zegt hoe lang je moet wachten" do
    opts =
      plug(
        bucket: "t-#{System.unique_integer([:positive])}",
        max: 1,
        window_ms: 60_000,
        by: :user
      )

    RateLimit.call(met_gebruiker("c"), opts)
    conn = RateLimit.call(met_gebruiker("c"), opts)

    assert conn.status == 429
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["60"]
  end
end
