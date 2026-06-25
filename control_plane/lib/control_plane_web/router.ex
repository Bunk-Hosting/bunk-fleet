defmodule ControlPlaneWeb.Router do
  use ControlPlaneWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Worker-node API: everything in `:api` plus agent-token bearer authentication.
  pipeline :node_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.NodeAuth
  end

  scope "/api", ControlPlaneWeb do
    pipe_through :api
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
