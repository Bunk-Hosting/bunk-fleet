defmodule ControlPlane.MixProject do
  use Mix.Project

  def project do
    [
      app: :control_plane,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: dialyzer(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ControlPlane.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh, :public_key]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Dialyzer's PLT is expensive to build and cheap to cache, so it lives in the
  # repo path CI caches rather than the default build directory.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # Mix and ExUnit are in the PLT so Dialyzer can see through the test
      # helpers and the release tasks rather than reporting unknown functions.
      plt_add_apps: [:mix, :ex_unit]
    ]
  end

  defp deps do
    [
      # 1.7.24 or newer: 1.7.23 carries GHSA-6983-jfq8-485w (HIGH — unbounded
      # channel joins per transport, a denial of service from a handful of
      # connections) and GHSA-63mc-hw7g-86rr. This platform serves WebSockets to
      # the public internet, so "few connections" is not a theoretical attacker.
      {:phoenix, "~> 1.7.24"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:pbkdf2_elixir, "~> 2.0"},
      {:nimble_totp, "~> 1.0"},
      # WebAuthn/FIDO2 voor passkeys: attestatie- en assertieverificatie.
      {:wax_, "~> 0.7"},
      {:eqrcode, "~> 0.2"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      # Used directly by config/runtime.exs for the SMTP CA bundle — it arrives
      # transitively via req/finch too, but a direct use deserves a direct dep.
      {:castore, "~> 1.0"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      # LiveViewTest DOM assertions (phoenix_live_view 1.2+) need an HTML parser.
      {:lazy_html, ">= 0.1.0", only: :test},

      # Static analysis. Credo is the style/consistency linter, Dialyzer the type
      # checker — the Elixir answers to the ruff and mypy the guidelines ask for.
      # Both dev/test only: neither ships in the release.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Fails the build on a dependency with a published CVE — "scan before
      # deployment", for the Hex tree.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
