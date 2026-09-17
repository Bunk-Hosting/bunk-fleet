defmodule ControlPlaneWeb.Plugs.AdminAuditLog do
  @moduledoc """
  Legt vast wie welke beheerhandeling deed.

  Er zijn twee beheerders. Het grootboek zei tot nu toe "handmatige aanpassing
  door beheerder" zonder te zeggen door wie, en een verwijderde gebruiker of een
  gewijzigde rol liet helemaal geen spoor na. Bij geld en bij andermans account
  is "er is iets gebeurd" te weinig: de vraag die achteraf gesteld wordt is wie.

  Alleen handelingen, geen leesverzoeken. Een beheerder die een lijst opent is
  geen gebeurtenis; elke GET meelopen zou de log vullen met ruis waarin de
  regels die ertoe doen verdwijnen.

  Wat er in staat: wie, wat, welk pad, welke uitkomst. Geen request body -- daar
  zitten bedragen en e-mailadressen in, en een log is geen plek die zichzelf
  opruimt. Het pad bevat wel de id waar de handeling over ging, want zonder dat
  is de regel niet na te trekken.

  Dit is een spoor in de applicatielog en geen onveranderlijk auditlogboek: wie
  de container kan lezen kan hem ook wissen. Het is de goedkope helft van het
  probleem, en die bestond nog niet.
  """
  import Plug.Conn

  require Logger

  alias ControlPlane.Accounts.User

  @behaviour Plug

  # GET en HEAD veranderen niets; die horen hier niet in.
  @veranderende_methodes ~w(POST PUT PATCH DELETE)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @veranderende_methodes do
    register_before_send(conn, &schrijf/1)
  end

  def call(conn, _opts), do: conn

  defp schrijf(conn) do
    Logger.info("beheerhandeling",
      admin: actor(conn),
      methode: conn.method,
      pad: conn.request_path,
      uitkomst: conn.status
    )

    conn
  end

  defp actor(%Plug.Conn{assigns: %{current_user: %User{} = user}}), do: user.email
  defp actor(_conn), do: "onbekend"
end
