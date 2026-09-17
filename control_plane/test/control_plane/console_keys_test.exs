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

  import Bitwise

  alias ControlPlane.Console.Keys

  # Expliciete sleutels in plaats van de globale configuratie verzetten: dat
  # laatste lekt naar tests die er parallel naast draaien.
  defp sleutel, do: :crypto.strong_rand_bytes(32)

  test "de gegenereerde sleutel is er een die ssh kan gebruiken" do
    # Dit is de enige eis die telt: `Console.KeyCb` doet precies deze twee
    # stappen om de sleutel aan de SSH-client te geven. Een sleutel die hier
    # struikelt geeft een console die weigert zonder uit te leggen waarom.
    {pem, publiek} = Keys.generate()

    assert [entry | _] = :public_key.pem_decode(pem)
    assert {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = :public_key.pem_entry_decode(entry)
    assert String.starts_with?(publiek, "ssh-rsa ")
  end

  test "de publieke regel is er een die een echte parser accepteert" do
    # Cloud-init zet deze regel in `authorized_keys`. Is het formaat net niet
    # goed, dan negeert sshd hem zonder klacht en merk je het pas als iemand de
    # console opent. Dit is dezelfde bibliotheek die de andere kant gebruikt.
    {_pem, publiek} = Keys.generate()

    assert [{sleutel, _attrs} | _] = :ssh_file.decode(publiek <> "\n", :openssh_key)
    assert {:RSAPublicKey, _modulus, _exponent} = sleutel
  end

  test "twee VPS'en krijgen niet dezelfde sleutel" do
    {pem_a, pub_a} = Keys.generate()
    {pem_b, pub_b} = Keys.generate()

    refute pem_a == pem_b
    refute pub_a == pub_b
  end

  test "versleutelen en weer openen levert dezelfde sleutel op" do
    {pem, _} = Keys.generate()

    k = sleutel()

    assert {:ok, verzegeld} = Keys.seal(pem, k)
    assert {:ok, ^pem} = Keys.unseal(verzegeld, k)
  end

  test "de opgeslagen vorm bevat de sleutel niet leesbaar" do
    # Anders is "versleuteld opgeslagen" een woord en geen eigenschap.
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem, sleutel())

    refute String.contains?(verzegeld, "PRIVATE KEY")
    refute verzegeld == pem
  end

  test "met een andere omgevingssleutel gaat hij niet open" do
    # Dit is de hele reden dat hij versleuteld staat: een databasedump zonder de
    # omgevingssleutel levert niets op.
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem, sleutel())

    assert :error = Keys.unseal(verzegeld, sleutel())
  end

  test "geknoei met de opgeslagen rij geeft geen sleutel in plaats van een verkeerde" do
    k = sleutel()
    {pem, _} = Keys.generate()
    {:ok, verzegeld} = Keys.seal(pem, k)

    # Eén bit omklappen in de ciphertext, niet "op nul zetten": stond daar al een
    # nul, dan veranderde er niets en slaagde de ontsleuteling gewoon. Precies
    # die test viel daardoor de ene keer wel en de andere keer niet om.
    <<kop::binary-size(30), byte, rest::binary>> = verzegeld
    geknoeid = kop <> <<bxor(byte, 0xFF)>> <> rest

    assert :error = Keys.unseal(geknoeid, k)
  end

  test "een ontbrekende of onbruikbare omgevingssleutel telt niet als sleutel" do
    # Half aanzetten zou een VPS opleveren met een sleutel die niemand meer kan
    # ontsleutelen: een console die stilletjes kapot is in plaats van een console
    # die er niet is. Daarom moet elk van deze waarden op `nil` uitkomen.
    for waarde <- [nil, "", "geen base64!", Base.encode64("te kort"), "x"] do
      assert Keys.parse_key(waarde) == nil, "#{inspect(waarde)} hoort geen sleutel te zijn"
    end

    assert Keys.parse_key(Base.encode64(String.duplicate("k", 32))) == String.duplicate("k", 32)
  end
end
