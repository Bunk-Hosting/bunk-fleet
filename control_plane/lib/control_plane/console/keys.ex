defmodule ControlPlane.Console.Keys do
  @moduledoc """
  Een eigen SSH-sleutelpaar per VPS voor de webterminal.

  Tot nu toe had het platform één console-sleutel, en die staat in de
  `authorized_keys` van elke klant-VPS. Dat betekent: wie die ene sleutel in
  handen krijgt heeft root op iedereen. Dat is geen theoretisch bezwaar maar de
  definitie van een single point of failure -- en het is nu goedkoop op te
  lossen, want er draaien er twee. Bij tweehonderd is dezelfde stap een
  migratie.

  ## Waarom de privésleutel versleuteld in de database staat

  De realistische manieren waarop zoiets weglekt zijn een databasedump, een
  back-up, en de omgeving van het proces. Zetten we de sleutels onversleuteld in
  de database, dan dekt dit alleen het geval "iemand leest .env.prod" af en
  verruilen we één probleem voor een ander.

  Versleuteld met een sleutel die alleen in de omgeving staat, zijn het twee
  verschillende inbraken: een dump zonder de omgevingssleutel levert niets op,
  en de omgevingssleutel zonder dump ook niet.

  ## Waarom RSA en niet Ed25519

  Ed25519 is korter en modern, maar de weg van OTP's `:public_key` naar een PEM
  die `:ssh` als gebruikerssleutel accepteert is daar minder recht. RSA-3072
  werkt met de code die er al staat (`Console.KeyCb` doet `pem_decode` gevolgd
  door `pem_entry_decode`) en is ruim voldoende. Een sleutel die aantoonbaar
  werkt is meer waard dan een sleutel die korter is.

  ## Als er geen omgevingssleutel is

  Dan gebeurt er niets: nieuwe VPS'en krijgen geen eigen sleutel en blijven de
  gedeelde gebruiken. Dat is bewust -- half aanzetten zou VPS'en opleveren met
  een sleutel die niemand meer kan ontsleutelen, en dat is een console die
  stilletjes kapot is in plaats van een console die er niet is.
  """
  require Logger

  # AES-256-GCM. De nonce staat vooraan en het authenticatielabel erachter, zodat
  # één blob genoeg is om weer open te krijgen.
  @nonce_bytes 12
  @tag_bytes 16
  @aad "bunk-console-key"

  @doc """
  Een vers sleutelpaar: de privésleutel als PEM, de publieke in het formaat dat
  in `authorized_keys` hoort.
  """
  @spec generate() :: {binary(), binary()}
  def generate do
    rsa = :public_key.generate_key({:rsa, 3072, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])

    publiek = {:RSAPublicKey, elem(rsa, 2), elem(rsa, 3)}

    openssh =
      [{publiek, [comment: ~c"bunk-console"]}]
      |> :ssh_file.encode(:openssh_key)
      |> to_string()
      |> String.trim()

    {pem, openssh}
  end

  @doc "Of er per VPS een sleutel gemaakt kan worden (er is een omgevingssleutel)."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(omgevingssleutel())

  @doc """
  Versleutelt een privésleutel voor opslag. `:error` als er geen
  omgevingssleutel is -- de aanroeper hoort dan niets op te slaan.
  """
  @spec seal(binary(), binary() | nil) :: {:ok, binary()} | :error
  def seal(pem, sleutel \\ nil)

  def seal(pem, sleutel) when is_binary(pem) do
    case sleutel || omgevingssleutel() do
      nil ->
        :error

      sleutel ->
        nonce = :crypto.strong_rand_bytes(@nonce_bytes)

        {ct, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, sleutel, nonce, pem, @aad, true)

        {:ok, nonce <> tag <> ct}
    end
  end

  @doc """
  Haalt een opgeslagen privésleutel weer open.

  `:error` bij een ontbrekende omgevingssleutel, een gewijzigde omgevingssleutel
  of geknoei met de rij: het authenticatielabel van GCM vangt dat laatste, en
  dan is er geen sleutel in plaats van een verkeerde.
  """
  @spec unseal(binary(), binary() | nil) :: {:ok, binary()} | :error
  def unseal(verzegeld, sleutel \\ nil)

  def unseal(
        <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ct::binary>>,
        gegeven
      ) do
    case gegeven || omgevingssleutel() do
      nil ->
        :error

      sleutel ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, sleutel, nonce, ct, @aad, tag, false) do
          pem when is_binary(pem) -> {:ok, pem}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  def unseal(_verzegeld, _sleutel), do: :error

  # 32 bytes, base64 in de omgeving. Een sleutel van de verkeerde lengte is een
  # configuratiefout en geen reden om stilletjes iets zwakkers te doen.
  defp omgevingssleutel do
    parse_key((Application.get_env(:control_plane, :console) || [])[:key_encryption_key])
  end

  @doc """
  Leest een omgevingswaarde als sleutel, of `nil` als hij niet deugt.

  Publiek zodat een test over het formaat geen globale configuratie hoeft te
  verzetten -- dat lekt naar tests die er parallel naast draaien, en dat is
  precies hoe deze module ooit een andere testsuite liet omvallen.
  """
  @spec parse_key(term()) :: binary() | nil
  def parse_key(waarde) do
    case waarde do
      <<sleutel::binary-size(32)>> ->
        sleutel

      waarde when is_binary(waarde) and waarde != "" ->
        case Base.decode64(waarde) do
          {:ok, <<sleutel::binary-size(32)>>} ->
            sleutel

          _ ->
            Logger.warning(
              "CONSOLE_KEY_ENC is geen base64 van 32 bytes; per-VPS consolesleutels staan uit"
            )

            nil
        end

      _ ->
        nil
    end
  end
end
