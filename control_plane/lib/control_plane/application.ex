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
        ControlPlane.Accounts.LoginThrottle,
        # Tracks live console SSH sessions per user (duplicate keys = {:user, id}).
        {Registry, keys: :duplicate, name: ControlPlane.Console.Registry},
        # One entry per in-flight console relay, keyed by its relay token — this
        # is what the agent's dial-back looks itself up in.
        {Registry, keys: :unique, name: ControlPlane.Console.Relay.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: ControlPlane.Console.RelaySupervisor},
        ControlPlane.Console.Tickets
      ] ++
        reconciler_child() ++
        [
          # Start to serve requests, typically the last entry
          ControlPlaneWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ControlPlane.Supervisor]
    result = Supervisor.start_link(children, opts)

    # After the tree is up, so the warnings land in the same log stream as
    # everything else rather than ahead of the logger's own configuration.
    # Off in :test, where every protection is deliberately unset and the warnings
    # would be noise. Config rather than Mix.env(): Mix is not loaded inside a
    # release, and a compile-time constant here leaves a branch that can never run.
    if Application.get_env(:control_plane, :report_security_posture, true),
      do: ControlPlane.SecurityPosture.report()

    result
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
