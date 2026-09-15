import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :control_plane, ControlPlane.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "control_plane_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :control_plane, ControlPlaneWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YNPKvSxBXcNDgGiVltfVVndf2w4yOI46jilMXVbQCWG31Qct9/Gk7Qv9+DvpcGCK",
  server: false

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Fixed admin token for the operator/admin API in tests.
config :control_plane, admin_token: "test-admin-token"

# Fixed, known billing rates (money per resource-hour) so payout math is
# deterministic in tests. Units are abstract — see `ControlPlane.Billing`.
# Rates are given as strings (config is evaluated before deps like Decimal are
# loaded); `ControlPlane.Billing` coerces them to Decimal at runtime.
config :control_plane,
  billing_rates: %{
    vcpu: "0.010",
    ram_gb: "0.004",
    disk_gb: "0.0002"
  }

# Don't run the background node-health reconciler during tests: it would race
# against the Ecto SQL sandbox and the explicit reconciliation tests. Tests
# exercise the logic directly (and a short-interval Reconciler when needed).
config :control_plane, start_reconciler: false

# Capture sent mail in the test process's mailbox (assert_email_sent/1) instead
# of hitting any real adapter.
config :control_plane, ControlPlane.Mailer, adapter: Swoosh.Adapters.Test

# The Mollie client talks to a Req stub instead of api.mollie.com. An api_key has
# to be present or `Mollie.configured?/0` turns the endpoints off and the tests
# would be asserting against a disabled feature rather than the real one.
config :control_plane, :mollie,
  api_key: "test_stub_key",
  req_options: [plug: {Req.Test, ControlPlane.Mollie}]

# The boot-time security-posture report is about production gaps; in :test every
# protection is deliberately unset, so it would print three warnings per run.
config :control_plane, report_security_posture: false

# Geen update-commando's bij het opstarten: die zouden buiten de
# databasesandbox om schrijven en tests van elkaar laten afhangen.
config :control_plane, dispatch_agent_updates: false
