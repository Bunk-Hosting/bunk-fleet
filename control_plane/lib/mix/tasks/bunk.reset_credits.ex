defmodule Mix.Tasks.Bunk.ResetCredits do
  @shortdoc "Zet alle tegoeden terug op nul met een zichtbare correctieregel"

  @moduledoc """
  Zet het tegoed van iedere gebruiker terug op nul.

      mix bunk.reset_credits          # laat zien wat er zou gebeuren
      mix bunk.reset_credits --doen   # en voer het uit

  Het werk zelf staat in `ControlPlane.Credits.Reset`; daar staat ook waarom het
  met een correctieregel gebeurt en niet door regels te verwijderen. Op productie
  draait een release zonder Mix — gebruik daar `ControlPlane.Release.reset_credits/1`.
  """

  use Mix.Task

  alias ControlPlane.Credits.Reset

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [doen: :boolean])

    Mix.Task.run("app.start")

    Reset.plan()
    |> toon()
    |> voer_uit(Keyword.get(opts, :doen, false))
  end

  defp toon([]) do
    Mix.shell().info("Alle tegoeden staan al op nul.")
    []
  end

  defp toon(regels) do
    Enum.each(regels, fn %{email: email, saldo: saldo} ->
      Mix.shell().info("#{String.pad_trailing(email, 34)} #{Reset.euro(saldo)} -> 0.00 EUR")
    end)

    regels
  end

  defp voer_uit([], _doen?), do: :ok

  defp voer_uit(regels, false) do
    Mix.shell().info("\nProefdraai over #{length(regels)} tegoed(en). Voeg --doen toe.")
  end

  defp voer_uit(regels, true) do
    Reset.apply!()
    Mix.shell().info("\n#{length(regels)} tegoed(en) teruggezet.")
  end
end
