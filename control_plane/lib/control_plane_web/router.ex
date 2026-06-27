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

  # Operator/admin LiveView dashboard.
  scope "/", ControlPlaneWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  # Customer portal: public auth pages.
  scope "/", ControlPlaneWeb do
    pipe_through :browser

    get "/login", UserSessionController, :new
    post "/login", UserSessionController, :create
    get "/login/mfa", UserSessionController, :mfa_new
    post "/login/mfa", UserSessionController, :mfa_create
    get "/register", UserRegistrationController, :new
    post "/register", UserRegistrationController, :create
    delete "/logout", UserSessionController, :delete
  end

  # Customer portal: authenticated area.
  scope "/", ControlPlaneWeb do
    pipe_through [:browser, :require_authenticated]

    live_session :dashboard,
      on_mount: [
        {ControlPlaneWeb.UserAuth, :ensure_authenticated},
        {ControlPlaneWeb.UserAuth, :current_path}
      ],
      layout: {ControlPlaneWeb.Layouts, :dashboard} do
      live "/dashboard", CustomerDashboardLive, :index
      live "/dashboard/vps", VpsListLive, :index
      live "/dashboard/vps/new", VpsNewLive, :index
      live "/dashboard/vps/:id", VpsDetailLive, :index
      live "/dashboard/vps/:id/console", ConsoleLive, :index
      live "/dashboard/beveiliging", SecurityLive, :index
      live "/dashboard/billing", BillingLive, :index
      live "/dashboard/billing/invoices", InvoiceListLive, :index
    end

    live_session :portal, on_mount: [{ControlPlaneWeb.UserAuth, :ensure_authenticated}] do
      live "/app", PortalLive, :index
      live "/app/host", HostLive, :index
      live "/app/topup", TopupLive, :index
      live "/app/vps/:id/console", ConsoleLive, :index
    end
  end

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

  # User accounts: open registration/login, then authenticated session routes.
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

    # Self-service VPS lifecycle, scoped to the authenticated owner.
    resources "/vpses", VpsController, only: [:index, :show, :create, :delete]
    post "/vpses/:id/start", VpsController, :start
    post "/vpses/:id/stop", VpsController, :stop

    # The caller's own metered usage and cost.
    get "/billing/usage", BillingController, :usage
  end

  # Operator self-service: onboard nodes + track earnings (role-gated).
  scope "/api/v1/operator", ControlPlaneWeb do
    pipe_through :operator_api

    post "/enroll-tokens", OperatorController, :create_enroll_token
    get "/nodes", OperatorController, :nodes
    get "/earnings", OperatorController, :earnings
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
