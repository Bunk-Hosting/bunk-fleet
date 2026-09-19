defmodule ControlPlane.Accounts.BreachedPasswords do
  @moduledoc """
  Weigert wachtwoorden die al in een datalek staan.

  Twaalf tekens eisen is een ondergrens, geen garantie: `Wachtwoord123!` haalt
  die grens en staat in elke lijst die een aanvaller al heeft. NIST SP 800-63B
  vraagt daarom niet om meer tekensoorten maar om een controle tegen bekend
  gelekt materiaal -- dat is het enige criterium dat iets zegt over of iemand
  anders dit wachtwoord al kan raden.

  ## Hoe het wachtwoord hier niet weglekt

  Er gaat nooit een wachtwoord of een volledige hash de deur uit. Van de SHA-1
  gaan alleen de eerste vijf tekens naar de dienst; die stuurt elk achtervoegsel
  terug dat met dat voorvoegsel begint (tientallen tot honderden), en het
  vergelijken gebeurt hier. De dienst leert daarmee hooguit dat iemand ergens
  een wachtwoord uit een bak van honderdduizenden koos. Dat heet k-anonimiteit
  en het is de reden dat dit verantwoord kan.

  SHA-1 is hier geen zwakte: het is een opzoeksleutel in andermans index, geen
  opslag. De wachtwoorden zelf staan als pbkdf2 in de database.

  ## Bewust toegeeflijk bij storing

  Kan de dienst niet worden bereikt, dan gaat de registratie door. Een klant die
  niet kan registreren omdat een derde partij plat ligt is een zekere schade;
  een wachtwoord dat één keer niet is gecontroleerd is een risico. Wel wordt het
  gelogd, want "staat altijd uit" en "werkt" zien er vanaf hier hetzelfde uit.
  """
  require Logger

  alias ControlPlane.Metrics

  @api "https://api.pwnedpasswords.com/range/"

  @doc """
  Of dit wachtwoord voorkomt in een bekend datalek.

  Bij twijfel `false`: zie de opmerking over storingen hierboven.
  """
  @spec breached?(String.t()) :: boolean()
  def breached?(wachtwoord) when is_binary(wachtwoord) do
    if enabled?(), do: opzoeken(wachtwoord), else: false
  end

  def breached?(_), do: false

  defp enabled?, do: Application.get_env(:control_plane, :check_breached_passwords, true)

  defp opzoeken(wachtwoord) do
    <<voorvoegsel::binary-size(5), achtervoegsel::binary>> =
      :crypto.hash(:sha, wachtwoord) |> Base.encode16(case: :upper)

    case Req.get(@api <> voorvoegsel, opties()) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        komt_voor?(body, achtervoegsel)

      {:ok, %{status: status}} ->
        overgeslagen("pwnedpasswords antwoordde #{status}")

      {:error, reden} ->
        overgeslagen("pwnedpasswords onbereikbaar (#{inspect(reden)})")
    end
  rescue
    exception ->
      overgeslagen("pwnedpasswords-controle mislukt: #{Exception.message(exception)}")
  end

  # Elke uitweg waarin een wachtwoord ongecontroleerd doorgaat, loopt hier langs
  # -- zodat er geen tak kan ontstaan die stil open valt.
  #
  # Tellen en niet alleen loggen: een logregel gaat voorbij en een teller blijft
  # staan. Zonder die teller zien "de controle staat al maanden uit" en "de
  # controle werkt" er vanaf hier hetzelfde uit, en dan is het de tweede tot
  # iemand toevallig het tegendeel merkt.
  defp overgeslagen(reden) do
    Logger.warning(reden <> "; wachtwoord niet gecontroleerd")
    Metrics.count(:hibp_skipped)
    false
  rescue
    # De teller mag nooit de reden zijn dat iemand niet kan registreren.
    _ -> false
  end

  # Het antwoord is "ACHTERVOEGSEL:aantal" per regel. Alleen de gelijkheid telt;
  # het aantal zegt hoe vaak het gelekt is en dat verandert de uitkomst niet.
  defp komt_voor?(body, achtervoegsel) do
    body
    |> String.split("\n")
    |> Enum.any?(fn regel ->
      regel |> String.split(":") |> List.first() |> String.trim() |> String.upcase() ==
        achtervoegsel
    end)
  end

  defp opties do
    [
      # Kort: dit zit vóór een registratie die een mens staat af te wachten.
      receive_timeout: 2_000,
      connect_options: [timeout: 2_000],
      retry: false,
      # Het antwoord mag niet door een proxy of cache bewaard worden: een
      # voorvoegsel plus een tijdstip is meer dan de dienst zelf krijgt.
      headers: [{"add-padding", "true"}]
    ] ++ Application.get_env(:control_plane, :pwned_req_options, [])
  end
end
