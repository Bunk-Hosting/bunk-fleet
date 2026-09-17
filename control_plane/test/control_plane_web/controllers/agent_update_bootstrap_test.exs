defmodule ControlPlaneWeb.AgentUpdateBootstrapTest do
  @moduledoc """
  `/agent-update.sh`: het script dat via `curl | sh` als root op een node landt.

  Dit had geen enkele test, terwijl het het meest ingrijpende dat we uitleveren
  is: het draait als root op hardware die niet van ons is, en het zet daar een
  systemd-timer neer die zichzelf blijft uitvoeren. Een fout hierin is geen 500
  maar een halve installatie op andermans machine.

  Het heredoc-gedeelte is het gevaarlijke stuk. Staat er in het ingebedde script
  een regel die toevallig het eindmarkering-woord is, dan valt de rest van het
  bestand buiten het heredoc en wordt shell-code. Dat is niet te zien aan de
  uitvoer -- alleen aan wat er daarna gebeurt.
  """
  use ControlPlaneWeb.ConnCase, async: true

  defp haal(conn), do: get(conn, ~p"/agent-update.sh")

  test "levert een shellscript uit", %{conn: conn} do
    conn = haal(conn)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "shellscript"
    assert response(conn, 200) =~ "#!/bin/sh"
  end

  test "heeft geen sessie nodig", %{conn: conn} do
    # Een node die zichzelf bijwerkt heeft geen inloggegevens; dit pad moet open
    # staan. Dat het open staat is een keuze en hoort vast te liggen.
    assert haal(conn).status == 200
  end

  test "zet de updater, de service en de timer neer en start hem", %{conn: conn} do
    script = response(haal(conn), 200)

    assert script =~ "/usr/local/bin/bunk-agent-update"
    assert script =~ "/etc/systemd/system/bunk-agent-update.service"
    assert script =~ "/etc/systemd/system/bunk-agent-update.timer"
    assert script =~ "systemctl enable --now bunk-agent-update.timer"
  end

  test "weigert te draaien als niet-root", %{conn: conn} do
    # ~S met een pipe als scheidingsteken: de haakjes van $(id -u) zouden een
    # ~s(...) voortijdig afsluiten, en dan leest de rest van het bestand als code.
    assert response(haal(conn), 200) =~ ~S|[ "$(id -u)" = "0" ]|
  end

  test "de ingebedde bestanden breken hun heredoc niet open", %{conn: conn} do
    # Dit is de fout die deze test bewaakt: een regel in het ingebedde script die
    # exact de eindmarkering is, sluit het heredoc te vroeg en laat de rest van
    # het bestand als shell-code uitvoeren.
    #
    # De openingsmarkering staat op de `cat`-regel zelf (`<<'UPD'`), dus als
    # losse regel hoort elke markering precies één keer voor te komen: het
    # einde. Twee is het foutgeval.
    script = response(haal(conn), 200)
    regels = String.split(script, "\n")

    for markering <- ~w(UPD UPDSVC UPDTMR) do
      los = Enum.count(regels, &(&1 == markering))
      opening = Enum.count(regels, &String.contains?(&1, "<<'#{markering}'"))

      assert opening == 1, "#{markering} wordt #{opening}x geopend; dat hoort 1x te zijn"

      assert los == 1,
             "#{markering} staat #{los}x als losse regel in het script; dat hoort 1x te zijn " <>
               "(meer betekent dat een ingebed bestand het heredoc vroegtijdig sluit)"
    end
  end

  test "is geldige shell", %{conn: conn} do
    # `sh -n` leest het script zonder het uit te voeren. Zonder deze test zou een
    # syntaxfout pas blijken op de machine van een ander, halverwege een uitrol.
    pad = Path.join(System.tmp_dir!(), "agent-update-#{System.unique_integer([:positive])}.sh")
    File.write!(pad, response(haal(conn), 200))

    {uitvoer, status} = System.cmd("sh", ["-n", pad], stderr_to_stdout: true)
    File.rm(pad)

    assert status == 0, "sh -n klaagt: #{uitvoer}"
  end
end
