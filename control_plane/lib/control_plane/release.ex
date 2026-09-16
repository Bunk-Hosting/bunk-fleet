defmodule ControlPlane.Release do
  @moduledoc """
  Release tasks runnable from the built binary without Mix on the target host,
  e.g. `bin/control_plane eval "ControlPlane.Release.migrate()"`.
  """
  @app :control_plane

  alias ControlPlane.Credits.Reset

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
    {:ok, _} = Application.ensure_all_started(@app)

    regels = Reset.plan()

    Enum.each(regels, fn %{email: email, saldo: saldo} ->
      IO.puts("#{String.pad_trailing(email, 34)} #{Reset.euro(saldo)} -> 0.00 EUR")
    end)

    if Keyword.get(opts, :doen, false) do
      Reset.apply!()
      IO.puts("\n#{length(regels)} tegoed(en) teruggezet.")
    else
      IO.puts("\nProefdraai over #{length(regels)} tegoed(en). Roep aan met doen: true.")
    end

    :ok
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
