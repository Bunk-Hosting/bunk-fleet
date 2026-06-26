# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :control_plane,
  ecto_repos: [ControlPlane.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Operator/admin API configuration.
#
# `admin_token` is the shared-secret bearer token required by the `/admin/v1` API
# (see `ControlPlaneWeb.Plugs.AdminAuth`); when unset the admin API denies all
# requests. `public_url` is the externally reachable control-plane URL embedded in
# node-enrollment install commands. `default_template_id` is the provider VM
# template used when provisioning a VPS without an explicit template.
config :control_plane,
  admin_token: System.get_env("ADMIN_TOKEN"),
  public_url: System.get_env("PUBLIC_URL", "https://control.bunkhosting.nl"),
  default_template_id: 9000

# Configures the endpoint
config :control_plane, ControlPlaneWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ControlPlaneWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ControlPlane.PubSub,
  live_view: [signing_salt: "ZPz1fXkR"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.

# VPS data-network range from which the IpPool hands out addresses to customer
# VPSes (Proxmox vmbr2 / 10.10.0.0/19). Override per-env in runtime.exs.
config :control_plane, :vps_network,
  prefix: 19,
  gateway: "10.10.0.1",
  range_start: "10.10.0.20",
  range_end: "10.10.4.254"

# Bank/iDEAL payment details shown to customers funding their wallet. Placeholders
# here; set the real values via runtime config before going live.
config :control_plane, :payment,
  iban: "NL00 BUNK 0000 0000 00",
  beneficiary: "Bunk Hosting",
  bic: "BUNKNL2A"

import_config "#{config_env()}.exs"
