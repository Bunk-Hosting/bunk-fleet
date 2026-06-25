defmodule ControlPlaneWeb.Router do
  use ControlPlaneWeb, :router

  # This app was generated with --no-html, so `use Phoenix.Router` does not bring
  # in the `live/3` macro; import it explicitly for the operator dashboard.
  import Phoenix.LiveView.Router

  # Browser pipeline for the (single) LiveView operator dashboard.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ControlPlaneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Operator/admin LiveView dashboard.
  scope "/", ControlPlaneWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/dashboard", DashboardLive, :index
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

  # User accounts: open registration/login, then authenticated session routes.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :api

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
  end

  scope "/api/v1", ControlPlaneWeb do
    pipe_through :user_api

    get "/auth/me", AuthController, :me
    delete "/auth/logout", AuthController, :logout
    delete "/auth/logout/all", AuthController, :logout_all

    # Self-service VPS lifecycle, scoped to the authenticated owner.
    resources "/vpses", VpsController, only: [:index, :show, :create, :delete]

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
