defmodule ControlPlane.Schijfruimte do
  @moduledoc """
  Kijkt hoe vol de schijf zit en meldt het voordat hij vol is.

  Waarom dit bestaat: op de machine waar dit draait staat naast het control
  plane ook de database, de frontend, de edge en de bouwomgeving. Een meting
  liet de schijf in één middag bouwen van 82% naar 88% gaan. Loopt hij vol, dan
  stopt Postgres met schrijven en ligt het hele platform plat -- en het eerste
  signaal zou dan een klant zijn die belt.

  De container ziet dezelfde onderliggende schijf als de host: zijn
  overlay-bestandssysteem rapporteert de cijfers van het bestandssysteem
  eronder. Dat is precies wat we willen weten.
  """
  require Logger

  # Vanaf hier is het een melding waard. Niet lager: op een machine die ook
  # bouwt schommelt het tussen de 80 en 85, en een waarschuwing die elke dag
  # afgaat leert iedereen hem te negeren.
  @drempel 88

  @doc """
  Het gebruikte percentage van het bestandssysteem waar `pad` op staat.

  `:onbekend` als `df` er niet is of iets onverwachts zegt -- dat is geen reden
  om een achtergrondronde te laten klappen.
  """
  @spec gebruikt_percentage(String.t()) :: {:ok, 0..100} | :onbekend
  def gebruikt_percentage(pad \\ "/") do
    case System.cmd("df", ["-P", pad], stderr_to_stdout: true) do
      {uitvoer, 0} -> lees(uitvoer)
      _ -> :onbekend
    end
  rescue
    # System.cmd klapt als het commando niet bestaat.
    _ -> :onbekend
  end

  @doc """
  Leest het percentage uit de uitvoer van `df -P`.

  Apart en publiek omdat dit het enige stuk is dat fout kan gaan op een manier
  die je wilt vastleggen: de opmaak van `df` verschilt per systeem, en de kolom
  die we willen is niet altijd dezelfde.
  """
  @spec lees(String.t()) :: {:ok, 0..100} | :onbekend
  def lees(uitvoer) do
    with [_kop, regel | _] <- String.split(uitvoer, "\n", trim: true),
         [_fs, _blokken, _gebruikt, _vrij, percentage | _] <- String.split(regel, ~r/\s+/),
         {getal, "%"} <- Integer.parse(percentage) do
      {:ok, getal}
    else
      _ -> :onbekend
    end
  end

  @doc "Of de schijf voller zit dan we willen."
  @spec te_vol?() :: false | {true, 0..100}
  def te_vol? do
    case gebruikt_percentage() do
      {:ok, pct} when pct >= @drempel -> {true, pct}
      _ -> false
    end
  end

  @doc "De drempel waarboven er gemeld wordt, zodat een test hem niet hoeft te raden."
  @spec drempel() :: 0..100
  def drempel, do: @drempel
end
