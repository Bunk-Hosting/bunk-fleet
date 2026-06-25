defmodule ControlPlane.Fleet.Events do
  @moduledoc """
  Thin, best-effort pub/sub wrapper for fleet state changes.

  The operator dashboard (`ControlPlaneWeb.DashboardLive`) subscribes to a single
  `"fleet:changes"` topic and reloads its data whenever something in the fleet
  moves. State-changing functions in `ControlPlane.Fleet` and
  `ControlPlane.Provisioning` call `broadcast_changed/1` *after* their database
  write has committed, passing a coarse `kind` (`:node`, `:vps`, `:nodes_offline`,
  `:usage`) describing what changed.

  ## Best-effort semantics

  Broadcasting is purely a UI hint and must never affect data integrity, so it is
  always invoked outside the business transaction and `broadcast_changed/1` can
  never raise: a PubSub failure is logged and swallowed. A dropped event is
  harmless — the dashboard's slow fallback refresh will pick the change up
  shortly after.
  """
  require Logger

  @pubsub ControlPlane.PubSub
  @topic "fleet:changes"

  @doc """
  The PubSub topic fleet changes are broadcast on.
  """
  def topic, do: @topic

  @doc """
  Subscribes the calling process to fleet-change events.

  Subscribers receive `{:fleet_changed, kind}` messages (see `broadcast_changed/1`).
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcasts a `{:fleet_changed, kind}` event to all subscribers.

  `kind` is a coarse atom describing what changed (e.g. `:node`, `:vps`,
  `:nodes_offline`, `:usage`). This is best-effort: any PubSub failure is logged
  and swallowed so it can never break the caller's business logic. Always returns
  `:ok`.
  """
  def broadcast_changed(kind) when is_atom(kind) do
    case Phoenix.PubSub.broadcast(@pubsub, @topic, {:fleet_changed, kind}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("fleet event broadcast (#{inspect(kind)}) failed: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "fleet event broadcast (#{inspect(kind)}) failed: #{Exception.message(exception)}"
      )

      :ok
  end
end
