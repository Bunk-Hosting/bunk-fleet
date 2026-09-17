defmodule ControlPlaneWeb.PrijsBijDeMachineTest do
  @moduledoc """
  De prijs van een draaiende VPS komt van de server en hangt niet aan de
  catalogus die de browser toevallig nog in het geheugen heeft.

  Waarom dit een eigen test verdient: de frontend leidde de prijs ooit zelf af
  door bij de specs een pakket te zoeken in `GET /packages`, en die lijst geeft
  alleen wat nog te koop is. Haalde je een pakket uit het aanbod, dan veranderde
  de VPS van elke bestaande klant in "Custom -- EUR 0,00", terwijl het abonnement
  gewoon doorliep. Het dashboard loog dan over de prijs van een machine die geld
  kost, op precies het scherm waar iemand kijkt als hij zich afvraagt waarom zijn
  saldo daalt.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  setup %{conn: conn} do
    user = confirmed_user_fixture()

    token =
      user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    pakket =
      Repo.insert!(%Package{
        name: "Brons",
        cpu_cores: 2,
        ram_gb: 4,
        disk_gb: 50,
        bandwidth_tb: 1,
        price_monthly: Decimal.new("12.00"),
        is_available: true
      })

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "web",
        region_id: region.id,
        vcpu: 2,
        ram_mb: 4096,
        disk_gb: 50,
        status: :active,
        owner_id: user.id,
        owner_email: user.email,
        package_id: pakket.id
      })
      |> Repo.insert!()

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      vps: vps,
      pakket: pakket
    }
  end

  test "een pakket dat uit het aanbod is gehaald houdt zijn prijs", %{
    conn: conn,
    pakket: pakket
  } do
    pakket |> Ecto.Changeset.change(%{is_available: false}) |> Repo.update!()

    assert %{"vpses" => [gevonden]} = conn |> get(~p"/api/v1/vpses") |> json_response(200)

    assert gevonden["package"]["name"] == "Brons"
    assert to_string(gevonden["package"]["price_monthly"]) == "12.00"
  end

  test "een pakket dat helemaal weg is geeft geen prijs in plaats van nul", %{
    conn: conn,
    pakket: pakket,
    vps: vps
  } do
    # Nul zou betekenen "gratis" en dat is een ander verhaal dan "onbekend". Het
    # scherm hoort hier niets te tonen, niet EUR 0,00.
    Repo.delete!(pakket)

    assert %{"vps" => gevonden} =
             conn |> get(~p"/api/v1/vpses/#{vps.id}") |> json_response(200)

    assert gevonden["package"] == nil
  end
end
