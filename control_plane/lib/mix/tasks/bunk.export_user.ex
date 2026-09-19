defmodule Mix.Tasks.Bunk.ExportUser do
  @shortdoc "Draait alles wat Bunk over één persoon weet uit als JSON"

  @moduledoc """
  Beantwoordt een inzage- of overdraagbaarheidsverzoek (AVG art. 15 en 20).

      mix bunk.export_user iemand@voorbeeld.nl
      mix bunk.export_user iemand@voorbeeld.nl --uit /tmp/export.json

  Zonder `--uit` gaat het naar standaarduitvoer, zodat het door `jq` kan. Wat er
  wel en niet in staat -- en waarom sleutels er niet in staan -- legt
  `ControlPlane.Privacy.Export` uit.

  Op productie draait een release zonder Mix; gebruik daar
  `ControlPlane.Release.export_user/2`.
  """

  use Mix.Task

  alias ControlPlane.Privacy.Export

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [uit: :string])

    email =
      case rest do
        [email] -> email
        _ -> Mix.raise("Gebruik: mix bunk.export_user <e-mailadres> [--uit bestand.json]")
      end

    Mix.Task.run("app.start")

    case Export.verzamel(email) do
      {:ok, gegevens} ->
        json = Jason.encode!(gegevens, pretty: true)

        case Keyword.get(opts, :uit) do
          nil ->
            Mix.shell().info(json)

          pad ->
            File.write!(pad, json)
            Mix.shell().info("Geschreven naar #{pad} (#{byte_size(json)} bytes)")
        end

      {:error, :not_found} ->
        Mix.raise("Geen account gevonden met het adres #{email}")
    end
  end
end
