defmodule ControlPlaneWeb.VpsDetailLive do
  @moduledoc "Customer VPS detail (replica of vps-frontend /dashboard/vps/[id])."
  use ControlPlaneWeb, :live_view

  import ControlPlaneWeb.DashboardComponents, only: [vps_status_badge: 1]
  alias ControlPlane.{Fleet, Provisioning}
  alias ControlPlane.Fleet.Events

  def mount(%{"id" => id}, _session, socket) do
    case Fleet.get_vps_for_owner(socket.assigns.current_user.id, id) do
      nil ->
        {:ok, assign(socket, vps: nil)}

      vps ->
        if connected?(socket), do: Events.subscribe()
        {:ok, assign(socket, vps: vps)}
    end
  end

  def handle_info({:fleet_changed, _}, %{assigns: %{vps: %{id: id}}} = socket) do
    {:noreply, assign(socket, vps: Fleet.get_vps_for_owner(socket.assigns.current_user.id, id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def handle_event(action, _params, %{assigns: %{vps: %{id: id}}} = socket)
      when action in ~w(start stop delete) do
    result =
      case action do
        "start" -> Provisioning.start_vps(id)
        "stop" -> Provisioning.stop_vps(id)
        "delete" -> Provisioning.delete_vps(id)
      end

    case result do
      {:ok, _} when action == "delete" -> {:noreply, push_navigate(socket, to: ~p"/dashboard/vps")}
      {:ok, _} -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "Actie kon niet worden uitgevoerd.")}
    end
  end

  def render(%{vps: nil} = assigns) do
    ~H"""
    <div class="text-center py-20">
      <p class="text-muted-foreground">VPS niet gevonden.</p>
      <.link navigate={~p"/dashboard/vps"} class="mt-4 inline-block text-primary hover:underline">Terug naar overzicht</.link>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.link navigate={~p"/dashboard/vps"} class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
        <span class="material-symbols-outlined" style="font-size:18px">arrow_back</span> Terug
      </.link>

      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="flex items-center gap-3">
          <h1 class="text-3xl font-bold tracking-tight">{@vps.name}</h1>
          <.vps_status_badge status={@vps.status} />
        </div>
        <div class="flex flex-wrap gap-2">
          <.link
            :if={@vps.status == :active}
            navigate={~p"/dashboard/vps/#{@vps.id}/console"}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-medium border border-primary/40 bg-background hover:border-primary hover:bg-primary/10 transition-all"
          >
            <span class="material-symbols-outlined mr-2" style="font-size:18px">terminal</span> Terminal
          </.link>
          <button
            phx-click="start"
            disabled={@vps.status != :stopped}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110 transition-all disabled:opacity-50 disabled:pointer-events-none"
          >
            Starten
          </button>
          <button
            phx-click="stop"
            data-confirm="Weet je zeker dat je deze VPS wilt stoppen?"
            disabled={@vps.status != :active}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-medium border border-primary/40 bg-background hover:border-primary hover:bg-primary/10 transition-all disabled:opacity-50 disabled:pointer-events-none"
          >
            Stoppen
          </button>
          <button
            phx-click="delete"
            data-confirm="Weet je zeker dat je deze VPS definitief wilt verwijderen?"
            disabled={@vps.status in [:deleting, :deleted]}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-medium bg-destructive text-destructive-foreground hover:bg-destructive/90 transition-all disabled:opacity-50 disabled:pointer-events-none"
          >
            Verwijderen
          </button>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6">
            <div class="text-lg font-semibold tracking-tight">Specificaties</div>
          </div>
          <div class="p-6 pt-0 space-y-2 text-sm">
            <div class="flex justify-between"><span class="text-muted-foreground">vCPU</span><span>{@vps.vcpu}</span></div>
            <div class="flex justify-between"><span class="text-muted-foreground">RAM</span><span>{div(@vps.ram_mb, 1024)} GB</span></div>
            <div class="flex justify-between"><span class="text-muted-foreground">Opslag</span><span>{@vps.disk_gb} GB</span></div>
          </div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6">
            <div class="text-lg font-semibold tracking-tight">Netwerk</div>
          </div>
          <div class="p-6 pt-0 space-y-2 text-sm">
            <div class="flex justify-between"><span class="text-muted-foreground">IP-adres</span><span class="font-mono">{@vps.ip_address || "—"}</span></div>
            <div class="flex justify-between"><span class="text-muted-foreground">Regio</span><span>{region_code(@vps)}</span></div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp region_code(%{region: %{code: code}}), do: code
  defp region_code(_), do: "—"
end
