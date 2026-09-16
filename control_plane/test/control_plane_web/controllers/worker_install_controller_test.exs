defmodule ControlPlaneWeb.WorkerInstallControllerTest do
  @moduledoc """
  Het installatiescript is een shellscript dat uit een Elixir-string wordt
  opgebouwd, dus de compiler zegt er niets over. Deze tests dekken wat daardoor
  stil kan breken: dat het template-VMID meekomt uit de configuratie in plaats
  van uit een getal dat iemand ooit in de tekst heeft gezet, en dat de
  templatestap er is en wordt aangeroepen.

  Een `bash -n` op het resultaat staat hier bewust niet bij: de container waarin
  de suite draait heeft geen bash, en een test die zich per omgeving anders
  gedraagt is geen test.
  """
  use ControlPlaneWeb.ConnCase, async: true

  defp install_script(conn) do
    conn = get(conn, "/install.sh")
    assert response_content_type(conn, :"x-shellscript")
    response(conn, 200)
  end

  describe "GET /install.sh" do
    test "levert een script af", %{conn: conn} do
      script = install_script(conn)

      assert script =~ "#!/usr/bin/env bash"
      assert script =~ "Bunk Worker installatie"
    end
  end

  describe "de Proxmox-template" do
    test "gebruikt het VMID uit de configuratie", %{conn: conn} do
      # Het getal hoort uit dezelfde bron te komen als wat de control plane bij
      # een bestelling meestuurt. Staat er een ander nummer in het script, dan
      # maakt de installer een template die niemand ooit kloont.
      verwacht = Application.get_env(:control_plane, :default_template_id, 9000)

      assert install_script(conn) =~ "PX_TMPL_ID=\"#{verwacht}\""
    end

    test "definieert de templatestap en roept hem aan", %{conn: conn} do
      script = install_script(conn)

      assert script =~ "ensure_proxmox_template() {"
      assert script =~ "ensure_proxmox_template ||"
    end

    test "controleert de opslag voordat er een image wordt gedownload", %{conn: conn} do
      # Eerst honderden megabytes ophalen en dan pas ontdekken dat de opslag niet
      # bestaat is de volgorde die we expliciet niet willen. Meten binnen de
      # functie zelf: de ESXi-stap haalt ook een image van cloud-images.ubuntu.com,
      # en die staat eerder in het script.
      body = proxmox_functie(install_script(conn))

      assert index_of(body, "pvesm status --storage") <
               index_of(body, "cloud-images.ubuntu.com/releases")
    end

    test "ruimt een halve template op in plaats van hem te laten staan", %{conn: conn} do
      # Blijft er een kapotte VM met dit VMID achter, dan slaat een volgende
      # installatie de templatestap over omdat hij "al bestaat".
      assert install_script(conn) =~ "qm destroy \"$PX_TMPL_ID\" --purge"
    end

    test "raakt de ESXi-kant niet", %{conn: conn} do
      script = install_script(conn)

      assert script =~ "ensure_esxi_template() {"
      assert script =~ "ensure_esxi_template ||"
    end
  end

  # Het stuk script tussen de functiekop en wat erop volgt, zodat een assertie
  # over volgorde niet per ongeluk de ESXi-tegenhanger meeneemt.
  defp proxmox_functie(script) do
    start = index_of(script, "ensure_proxmox_template() {")
    stop = index_of(script, "bold \"== Bunk Worker installatie")

    assert stop > start
    binary_part(script, start, stop - start)
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("niet gevonden in het script: #{needle}")
    end
  end
end
