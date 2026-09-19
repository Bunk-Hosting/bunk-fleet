defmodule ControlPlane.Release do
  @moduledoc """
  Release tasks runnable from the built binary without Mix on the target host,
  e.g. `bin/control_plane eval "ControlPlane.Release.migrate()"`.
  """
  @app :control_plane

  alias ControlPlane.Credits.Reset
  alias ControlPlane.Privacy.Export
  alias ControlPlane.Repo

  @doc "Runs all pending migrations for every configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Zet alle tegoeden terug op nul, met een correctieregel per gebruiker.

  Standaard een proefdraai: hij laat zien wat er zou gebeuren en schrijft niets.
  `doen: true` voert het uit. Draaien met

      bin/control_plane eval 'ControlPlane.Release.reset_credits(doen: true)'
  """
  @spec reset_credits(keyword()) :: :ok
  def reset_credits(opts \\ []) do
    load_app()
    doen? = Keyword.get(opts, :doen, false)

    # Alleen de repo starten, niet de hele applicatie. `ensure_all_started` zou
    # ook de webserver optuigen, en die poort is op productie al bezet door de
    # instantie die gewoon draait — de taak viel daar prompt op om.
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, fn _repo -> rapporteer(doen?) end)

    :ok
  end

  defp rapporteer(doen?) do
    regels = Reset.plan()
    Enum.each(regels, &toon/1)
    afronden(regels, doen?)
  end

  defp toon(%{email: email, saldo: saldo}) do
    IO.puts("#{String.pad_trailing(email, 34)} #{Reset.euro(saldo)} -> 0.00 EUR")
  end

  defp afronden([], _doen?) do
    IO.puts("Alle tegoeden staan al op nul.")
  end

  defp afronden(regels, true) do
    Reset.apply!()
    IO.puts("\n#{length(regels)} tegoed(en) teruggezet.")
  end

  defp afronden(regels, false) do
    IO.puts("\nProefdraai over #{length(regels)} tegoed(en). Roep aan met doen: true.")
  end

  @doc """
  Schrijft alles wat Bunk over één persoon weet naar `pad`, als JSON.

  De release-variant van `mix bunk.export_user`, want op productie draait een
  release zonder Mix. Een inzageverzoek heeft een termijn van een maand; dat
  haal je niet als het antwoord begint met "eerst even een omgeving met Mix
  optuigen".
  """
  def export_user(email, pad) do
    load_app()

    {:ok, uitkomst, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        case Export.verzamel(email) do
          {:ok, gegevens} ->
            File.write!(pad, Jason.encode!(gegevens, pretty: true))
            IO.puts("Geschreven naar #{pad}")
            :ok

          {:error, :not_found} ->
            IO.puts("Geen account gevonden met het adres #{email}")
            {:error, :not_found}
        end
      end)

    uitkomst
  end

  @doc "Rolls `repo` back to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
