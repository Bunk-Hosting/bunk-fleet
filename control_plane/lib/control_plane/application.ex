defmodule ControlPlane.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ControlPlaneWeb.Telemetry,
        ControlPlane.Repo,
        {DNSCluster, query: Application.get_env(:control_plane, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ControlPlane.PubSub},
        ControlPlane.RateLimiter,
        # Tracks live console SSH sessions per user (duplicate keys = {:user, id}).
        {Registry, keys: :duplicate, name: ControlPlane.Console.Registry}
      ] ++
        reconciler_child() ++
        [
          # Start to serve requests, typically the last entry
          ControlPlaneWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ControlPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The node-health reconciler is skipped in the test env (see config/test.exs)
  # so it can't interfere with the database sandbox; dev/prod start it normally.
  defp reconciler_child do
    if Application.get_env(:control_plane, :start_reconciler, true) do
      interval_ms = Application.get_env(:control_plane, :reconcile_interval_ms, 30_000)
      [{ControlPlane.Fleet.Reconciler, interval_ms: interval_ms}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ControlPlaneWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
