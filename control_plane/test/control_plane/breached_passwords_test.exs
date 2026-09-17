defmodule ControlPlane.BreachedPasswordsTest do
  @moduledoc """
  Wachtwoorden die al in een datalek staan worden geweigerd.

  Twaalf tekens eisen zegt niets over of iemand anders dit wachtwoord al kan
  raden; `Wachtwoord123!` haalt die grens en staat in elke lijst die een
  aanvaller heeft. NIST SP 800-63B vraagt daarom om een controle tegen bekend
  gelekt materiaal in plaats van om meer tekensoorten.

  Twee dingen liggen hier vast die makkelijk stilletjes de verkeerde kant op
  gaan: er mag nooit een heel wachtwoord of een hele hash de deur uit, en een
  storing bij de dienst mag geen registratie blokkeren.
  """
  # Niet async: de setup zet `:check_breached_passwords` aan, en dat is globale
  # configuratie. Staat hij aan terwijl een andere test parallel een gebruiker
  # registreert, dan doet díe test een Req-aanroep waarvoor in zijn eigen proces
  # geen stub bestaat. Het valt open (de registratie gaat door), maar het is
  # dezelfde soort lek waarmee de consolesleutel-test ooit een hele suite
  # omgooide. ExUnit draait sync-bestanden pas als alle async-tests klaar zijn,
  # dus zo kan het niemand meer raken.
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.BreachedPasswords

  @gelekt "Wachtwoord123!"
  @schoon "correct-paard-batterij-nietje-42"

  setup do
    Application.put_env(:control_plane, :check_breached_passwords, true)
    on_exit(fn -> Application.put_env(:control_plane, :check_breached_passwords, false) end)
    :ok
  end

  # Het antwoord van de dienst: achtervoegsels van de SHA-1, met een teller.
  defp dienst_kent(wachtwoorden) do
    Req.Test.stub(BreachedPasswords, fn conn ->
      body =
        Enum.map_join(wachtwoorden, "\r\n", fn w ->
          <<_voor::binary-size(5), achter::binary>> =
            :crypto.hash(:sha, w) |> Base.encode16(case: :upper)

          "#{achter}:42"
        end)

      Plug.Conn.send_resp(conn, 200, body)
    end)
  end

  defp dienst_ligt_plat do
    Req.Test.stub(BreachedPasswords, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
  end

  test "een gelekt wachtwoord wordt herkend" do
    dienst_kent([@gelekt])

    assert BreachedPasswords.breached?(@gelekt)
  end

  test "een wachtwoord dat er niet in staat komt door" do
    dienst_kent([@gelekt])

    refute BreachedPasswords.breached?(@schoon)
  end

  test "alleen de eerste vijf tekens van de hash gaan de deur uit" do
    # Dit is de hele reden dat deze controle verantwoord is. Zou het volledige
    # wachtwoord of de volledige hash meegaan, dan gaven we een derde partij bij
    # elke registratie een cadeautje.
    verwacht =
      :crypto.hash(:sha, @gelekt) |> Base.encode16(case: :upper) |> String.slice(0, 5)

    Req.Test.stub(BreachedPasswords, fn conn ->
      pad = conn.request_path

      assert String.ends_with?(pad, verwacht),
             "het pad #{pad} hoort op het voorvoegsel #{verwacht} te eindigen"

      refute String.contains?(pad, @gelekt)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    BreachedPasswords.breached?(@gelekt)
  end

  test "een storing blokkeert niemand" do
    # Een klant die niet kan registreren omdat een derde partij plat ligt is een
    # zekere schade; een wachtwoord dat één keer niet is gecontroleerd is een
    # risico. Dat is de afweging, en hij hoort deze kant op te vallen.
    dienst_ligt_plat()

    refute BreachedPasswords.breached?(@gelekt)
  end

  test "registreren met een gelekt wachtwoord lukt niet" do
    dienst_kent([@gelekt])

    assert {:error, changeset} =
             Accounts.register_user(%{email: "lek@bunk.test", password: @gelekt})

    assert {"komt voor in een bekend datalek" <> _, _} = changeset.errors[:password]
  end

  test "registreren met een schoon wachtwoord lukt wel" do
    dienst_kent([@gelekt])

    assert {:ok, _} = Accounts.register_user(%{email: "schoon@bunk.test", password: @schoon})
  end

  test "een te kort wachtwoord veroorzaakt geen verzoek naar buiten" do
    # Het is al afgekeurd; de dienst van een ander lastigvallen voegt niets toe.
    Req.Test.stub(BreachedPasswords, fn _conn -> raise "er ging een verzoek naar buiten" end)

    assert {:error, _} = Accounts.register_user(%{email: "kort@bunk.test", password: "kort"})
  end
end
