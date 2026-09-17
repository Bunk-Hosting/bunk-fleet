defmodule ControlPlane.ConsoleKeysTest do
  @moduledoc """
  Een eigen SSH-sleutelpaar per VPS voor de webterminal.

  Tot nu toe stond één platformsleutel in de `authorized_keys` van élke klant.
  Wie die in handen kreeg had root op iedereen. Wat hier vastligt is dat de
  vervanging ook echt werkt: een sleutel die `:ssh` kan gebruiken, versleuteld
  opgeslagen zodat een databasedump zonder de omgevingssleutel niets oplevert,
  en een VPS die de sleutel van een ander niet kan gebruiken.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Console.Keys

  @sleutel Base.encode64(:crypto.strong_rand_bytes(32))

  setup do
    oud = Application.get_env(:control_plane, :console) || []
    Application.put_env(:control_plane, :console, Keyword.put(oud, :key_encryption_key, @sleutel))
    on_exit(fn -> Application.put_env(:control_plane, :console, oud) end)
    :ok
  end

  test "de gegenereerde sleutel is er een die ssh kan gebruiken" do
    # Dit is de enige eis die telt: `Console.KeyCb` doet precies deze twee
    # stappen om de sleutel aan de SSH-client te geven. Een sleutel die hier
    # struikelt geeft een console die weigert zonder uit te leggen waarom.
    {pem, publiek} = Keys.generate()

    assert [entry | _] = :public_key.pem_decode(pem)
    assert {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = :public_key.pem_entry_decode(entry)
    assert String.starts_with?(publiek, "ssh-rsa ")
  end

  test "twee VPS'en krijgen niet dezelfde sleutel" do
    {pem_a, pub_a} = Keys.generate()
    {pem_b, pub_b} = Keys.generate()

    refute pem_a == pem_b
    refute pub_a == pub_b
  end

  test "versleutelen en weer openen levert dezelfde sleutel op" do
    {pem, _} = Keys.generate()

    assert {:ok, verzegeld} = Keys.seal(pem)
    assert {:ok, ^pem} = Keys.unseal(verzegeld)
  end

  test "de opgeslagen vorm bevat de sleutel niet leesbaar" do
    # Anders is "versleuteld opgeslagen" een woord en geen eigenschap.
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem)

    refute String.contains?(verzegeld, "PRIVATE KEY")
    refute verzegeld == pem
  end

  test "met een andere omgevingssleutel gaat hij niet open" do
    # Dit is de hele reden dat hij versleuteld staat: een databasedump zonder de
    # omgevingssleutel levert niets op.
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem)

    oud = Application.get_env(:control_plane, :console)

    Application.put_env(
      :control_plane,
      :console,
      Keyword.put(oud, :key_encryption_key, Base.encode64(:crypto.strong_rand_bytes(32)))
    )

    assert :error = Keys.unseal(verzegeld)
    Application.put_env(:control_plane, :console, oud)
  end

  test "geknoei met de opgeslagen rij geeft geen sleutel in plaats van een verkeerde" do
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem)

    <<kop::binary-size(30), rest::binary>> = verzegeld
    geknoeid = kop <> <<0>> <> binary_part(rest, 1, byte_size(rest) - 1)

    assert :error = Keys.unseal(geknoeid)
  end

  test "zonder omgevingssleutel gebeurt er niets" do
    # Half aanzetten zou een VPS opleveren met een sleutel die niemand meer kan
    # ontsleutelen: een console die stilletjes kapot is.
    oud = Application.get_env(:control_plane, :console)
    Application.put_env(:control_plane, :console, Keyword.delete(oud, :key_encryption_key))

    refute Keys.enabled?()
    assert :error = Keys.seal("wat dan ook")

    Application.put_env(:control_plane, :console, oud)
  end

  test "een omgevingssleutel van de verkeerde lengte telt niet als sleutel" do
    oud = Application.get_env(:control_plane, :console)

    Application.put_env(
      :control_plane,
      :console,
      Keyword.put(oud, :key_encryption_key, Base.encode64("te kort"))
    )

    refute Keys.enabled?()
    Application.put_env(:control_plane, :console, oud)
  end
end
