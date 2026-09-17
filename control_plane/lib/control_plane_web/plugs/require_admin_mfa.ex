defmodule ControlPlaneWeb.Plugs.RequireAdminMfa do
  @moduledoc """
  Eist een tweede factor op het beheerpaneel.

  Achter deze pijplijn staat alles: elk account, elke VPS van elke klant, en de
  knop die tegoed bijboekt. Eén gestolen wachtwoord of één meegelezen sessie mag
  dat niet waard zijn. Een beheerder die geen tweede factor heeft ingesteld
  krijgt hier `403 admin_mfa_required` -- geen data, geen lijst, niets.

  Een passkey telt net zo goed als een authenticator-app. Een passkey is aan het
  domein gebonden en daarmee bestand tegen phishing; eisen dat er dáárnaast ook
  nog TOTP staat zou strenger lijken en niets toevoegen.

  Dit is bewust geen stap-voor-stap-verificatie per handeling. Die hoort bij de
  handelingen die geld verplaatsen en is een aparte keuze; dit is de ondergrens:
  wie hier binnenkomt heeft meer dan een wachtwoord nodig gehad.

  Staat na `RequireAdmin`, zodat een gewone gebruiker `forbidden` krijgt en niet
  te horen krijgt dat er een beheerdersdrempel bestaat die hij bijna haalde.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Accounts

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    if Accounts.has_second_factor?(user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "admin_mfa_required",
        detail:
          "Het beheerpaneel vraagt een tweede factor. Zet een authenticator-app " <>
            "of een passkey aan onder Beveiliging."
      })
      |> halt()
    end
  end

  def call(conn, _opts) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"}) |> halt()
  end
end
