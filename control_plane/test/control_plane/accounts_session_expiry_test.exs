defmodule ControlPlane.AccountsSessionExpiryTest do
  @moduledoc """
  Een sessie hoort te verlopen. Tot nu toe deed hij dat alleen op leeftijd —
  zestig dagen na het inloggen — en verder nooit, wat betekende dat een token dat
  ergens bleef liggen twee maanden lang bruikbaar bleef. Deze tests leggen beide
  grenzen vast: te oud, en te lang stil.
  """
  use ControlPlane.DataCase, async: true

  import Ecto.Query

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.UserToken
  alias ControlPlane.Repo

  defp user(email) do
    {:ok, u} =
      Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})

    u
  end

  # De schijf van de tijd terugdraaien is hier eerlijker dan wachten: de grenzen
  # staan in dagen en een test die echt wacht bestaat niet.
  defp verouder(token, dagen_geleden_aangemaakt, dagen_geleden_gebruikt) do
    hashed = :crypto.hash(:sha256, token)
    nu = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in UserToken, where: t.token == ^hashed)
    |> Repo.update_all(
      set: [
        inserted_at: DateTime.add(nu, -dagen_geleden_aangemaakt * 86_400, :second),
        last_used_at: DateTime.add(nu, -dagen_geleden_gebruikt * 86_400, :second)
      ]
    )
  end

  describe "een geldige sessie" do
    test "geeft de gebruiker terug" do
      u = user("sessie1@bunk.test")
      token = Accounts.generate_user_session_token(u)

      assert %{id: id} = Accounts.get_user_by_session_token(token)
      assert id == u.id
    end

    test "schuift de stiltegrens mee zolang hij gebruikt wordt" do
      u = user("sessie2@bunk.test")
      token = Accounts.generate_user_session_token(u)

      # Zes dagen stil: nog net binnen de grens van zeven. Het gebruik zelf moet
      # de klok resetten, anders loopt een sessie alsnog af terwijl iemand zit
      # te werken.
      verouder(token, 6, 6)
      assert Accounts.get_user_by_session_token(token)

      verouder(token, 12, 6)
      assert Accounts.get_user_by_session_token(token)
    end
  end

  describe "een sessie die verloopt" do
    test "wordt geweigerd na te lang stilzitten" do
      u = user("sessie3@bunk.test")
      token = Accounts.generate_user_session_token(u)

      %{idle_days: idle} = Accounts.session_limits()
      verouder(token, idle + 1, idle + 1)

      refute Accounts.get_user_by_session_token(token)
    end

    test "wordt geweigerd als hij te oud is, ook al is hij net nog gebruikt" do
      u = user("sessie4@bunk.test")
      token = Accounts.generate_user_session_token(u)

      # Dit is de grens die gebruik níét kan oprekken. Iemand die elke dag
      # inlogt zou anders nooit opnieuw hoeven bewijzen wie hij is.
      %{max_days: max} = Accounts.session_limits()
      verouder(token, max + 1, 0)

      refute Accounts.get_user_by_session_token(token)
    end

    test "raakt een andere sessie van dezelfde gebruiker niet" do
      u = user("sessie5@bunk.test")
      oud = Accounts.generate_user_session_token(u)
      vers = Accounts.generate_user_session_token(u)

      %{idle_days: idle} = Accounts.session_limits()
      verouder(oud, idle + 1, idle + 1)

      refute Accounts.get_user_by_session_token(oud)
      assert Accounts.get_user_by_session_token(vers)
    end
  end

  describe "opruimen" do
    test "verwijdert alleen wat toch al geweigerd werd" do
      u = user("sessie6@bunk.test")
      dood = Accounts.generate_user_session_token(u)
      levend = Accounts.generate_user_session_token(u)

      %{idle_days: idle} = Accounts.session_limits()
      verouder(dood, idle + 2, idle + 2)

      assert Accounts.purge_expired_sessions() == 1
      assert Accounts.get_user_by_session_token(levend)
    end

    test "laat een schone tabel met rust" do
      u = user("sessie7@bunk.test")
      _token = Accounts.generate_user_session_token(u)

      assert Accounts.purge_expired_sessions() == 0
    end
  end

  describe "de grenzen zelf" do
    test "stilte loopt eerder af dan leeftijd" do
      # Andersom zou de stiltegrens nooit iets doen. Dat is geen smaak maar de
      # voorwaarde waaronder de hele maatregel zin heeft.
      %{max_days: max, idle_days: idle} = Accounts.session_limits()
      assert idle < max
    end
  end
end
