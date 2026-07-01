defmodule ControlPlaneWeb.Router do
  use ControlPlaneWeb, :router

  # This app was generated with --no-html, so `use Phoenix.Router` does not bring
  # in the `live/3` macro; import it explicitly for the operator dashboard.
  import Phoenix.LiveView.Router
  import ControlPlaneWeb.UserAuth

  # Browser pipeline for the (single) LiveView operator dashboard.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ControlPlaneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  # Browser routes that require an authenticated portal user.
  pipeline :require_authenticated do
    plug :require_authenticated_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Throttle the public browser auth pages (login/register/MFA) per-client to
  # blunt password + 6-digit-TOTP brute force. Keyed on CF-Connecting-IP.
  pipeline :auth_throttle do
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "browser_auth", max: 20, window_ms: 60_000
  end

  # Operator/admin LiveView dashboard.
  # Operator/admin fleet dashboard — shows EVERY node + EVERY customer's VPS, so
  # it must never be reachable unauthenticated or by a regular customer. Gated to
  # staff (operator/admin), mirroring RequireOperator.
  scope "/", ControlPlaneWeb do
    pipe_through [:browser, :require_authenticated]

    live_session :operator_dashboard,
      on_mount: [{ControlPlaneWeb.UserAuth, :ensure_staff}] do
      live "/", DashboardLive, :index
    end
  end

  # Customer portal: public auth pages.
  scope "/", ControlPlaneWeb do
    pipe_through [:browser, :auth_throttle]

    get "/login", UserSessionController, :new
    post "/login", UserSessionController, :create
    get "/login/mfa", UserSessionController, :mfa_new
    post "/login/mfa", UserSessionController, :mfa_create
    get "/register", UserRegistrationController, :new
    post "/register", UserRegistrationController, :create
    delete "/logout", UserSessionController, :delete
  end

  # The customer portal is served entirely by the Next.js frontend against the
  # JSON API (`/api/v1/*`) and the console WebSocket (`/ws/console/:id`). The old
  # server-rendered LiveView customer stack (:dashboard / :portal) was removed:
  # it was unreachable behind the edge and its create paths didn't charge the
  # wallet, so keeping it was pure attack surface.

  # Worker-node API: everything in `:api` plus agent-token bearer authentication.
  pipeline :node_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.NodeAuth
  end

  # Operator/admin API: JSON plus shared-secret admin-token bearer authentication.
  pipeline :admin_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.AdminAuth
  end

  # End-user/operator API: JSON plus per-user session-token bearer authentication.
  pipeline :user_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.ApiAuth
  end

  # Operator self-service API: authenticated *and* gated to the :operator/:admin role.
  pipeline :operator_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.ApiAuth
    plug ControlPlaneWeb.Plugs.RequireOperator
  end

  # Admin panel API: authenticated on the caller's OWN session token and gated to
  # the :admin role (distinct from /admin/v1/* which uses a shared secret).
  pipeline :admin_session_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.ApiAuth
    plug ControlPlaneWeb.Plugs.RequireAdmin
  end

  scope "/api", ControlPlaneWeb do
    pipe_through :api
  end

  # Public worker installer script (curl | bash).
  scope "/", ControlPlaneWeb do
    pipe_through :api
    get "/install.sh", WorkerInstallController, :script
  end

  # Open, unauthenticated auth endpoints are rate-limited per client IP to blunt
  # credential-stuffing and registration spam.
  pipeline :auth_public do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "auth", max: 30, window_ms: 60_000
  end

  # Public webhook: still no auth (Mollie can't authenticate), but rate-limited so
  # it can't be flooded to amplify outbound get_payment fetches / hammer Mollie.
  # 120/min/ip is far above Mollie's real callback rate for one merchant.
  pipeline :webhook do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "webhook", max: 120, window_ms: 60_000
  end

  # Public Mollie webhook. Safety comes from fetch-to-verify + idempotent,
  # amount-checked crediting; the rate limit only caps abuse volume.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :webhook

    post "/billing/mollie/webhook", MollieController, :webhook
  end

  scope "/api/v1", ControlPlaneWeb do
    pipe_through :auth_public

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login

    # Public, read-only VPS package catalog.
    get "/packages", PackageController, :index
  end

  scope "/api/v1", ControlPlaneWeb do
    pipe_through :user_api

    get "/auth/me", AuthController, :me
    delete "/auth/logout", AuthController, :logout
    delete "/auth/logout/all", AuthController, :logout_all

    # Two-factor (TOTP) — bunk-fleet's own Accounts feature, exposed for the UI.
    get "/auth/totp/setup", AuthController, :totp_setup
    post "/auth/totp/setup", AuthController, :totp_confirm
    delete "/auth/totp/disable", AuthController, :totp_disable

    # Self-service VPS lifecycle, scoped to the authenticated owner.
    resources "/vpses", VpsController, only: [:index, :show, :create, :delete]
    post "/vpses/:id/start", VpsController, :start
    post "/vpses/:id/stop", VpsController, :stop
    post "/vpses/:id/console-ticket", ConsoleController, :create_ticket

    # Self-service host onboarding (opt-in path; promotes :user -> :operator).
    get "/host/status", HostController, :status
    post "/host/activate", HostController, :activate
    get "/host/regions", HostController, :regions

    # The caller's own prepaid wallet: balance, ledger movements, top-ups.
    get "/billing/wallet", BillingController, :wallet

    # The caller's own metered usage and cost.
    get "/billing/usage", BillingController, :usage

    # Mollie wallet top-up: create a payment, return its checkout URL.
    post "/billing/topup", MollieController, :topup
  end

  # Operator self-service: onboard nodes + track earnings (role-gated).
  scope "/api/v1/operator", ControlPlaneWeb do
    pipe_through :operator_api

    post "/enroll-tokens", OperatorController, :create_enroll_token
    get "/nodes", OperatorController, :nodes
    get "/earnings", OperatorController, :earnings
  end

  # Session-authenticated admin panel (role :admin). Powers the dashboard's admin
  # section: platform stats, user management, a fleet-wide VPS view + lifecycle
  # actions, and a node overview.
  scope "/api/v1/admin", ControlPlaneWeb.Admin do
    pipe_through :admin_session_api

    get "/stats", PanelController, :stats
    get "/users", PanelController, :users
    patch "/users/:id", PanelController, :update_user
    post "/users/:id/credit", PanelController, :credit_user
    get "/vpses", PanelController, :vpses
    post "/vpses/:id/start", PanelController, :vps_start
    post "/vpses/:id/stop", PanelController, :vps_stop
    delete "/vpses/:id", PanelController, :vps_delete
    get "/nodes", PanelController, :nodes
  end

  # Browser console WebSocket. No router pipeline (a WS upgrade isn't JSON); the
  # single-use ticket in the query string is the credential, redeemed here.
  scope "/ws", ControlPlaneWeb do
    get "/console/:id", ConsoleController, :ws
  end

  # bunk-agent onboarding / heartbeat / command API.
  scope "/v1", ControlPlaneWeb do
    pipe_through :api

    post "/enroll", EnrollController, :enroll
  end

  scope "/v1", ControlPlaneWeb do
    pipe_through :node_api

    post "/heartbeat", HeartbeatController, :create
    get "/commands", CommandController, :index
    post "/commands/:id/result", CommandController, :result
  end

  # Operator/admin API.
  scope "/admin/v1", ControlPlaneWeb.Admin do
    pipe_through :admin_api

    resources "/regions", RegionController, only: [:index, :create]
    post "/enroll-tokens", EnrollTokenController, :create
    get "/nodes", NodeController, :index
    get "/vpses", VpsController, :index
    post "/vpses", VpsController, :create
    delete "/vpses/:id", VpsController, :delete
    get "/billing/usage", BillingController, :usage
    get "/credits", CreditController, :show
    post "/credits", CreditController, :create
    get "/topups", TopupController, :index
    post "/topups/:id/confirm", TopupController, :confirm
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:control_plane, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ControlPlaneWeb.Telemetry
    end
  end
end
