import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :control_plane, ControlPlane.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "control_plane_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :control_plane, ControlPlaneWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YNPKvSxBXcNDgGiVltfVVndf2w4yOI46jilMXVbQCWG31Qct9/Gk7Qv9+DvpcGCK",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Fixed admin token for the operator/admin API in tests.
config :control_plane, admin_token: "test-admin-token"

# Fixed, known billing rates (money per resource-hour) so payout math is
# deterministic in tests. Units are abstract — see `ControlPlane.Billing`.
config :control_plane,
  billing_rates: %{
    vcpu: Decimal.new("0.010"),
    ram_gb: Decimal.new("0.004"),
    disk_gb: Decimal.new("0.0002")
  }

# Don't run the background node-health reconciler during tests: it would race
# against the Ecto SQL sandbox and the explicit reconciliation tests. Tests
# exercise the logic directly (and a short-interval Reconciler when needed).
config :control_plane, start_reconciler: false
