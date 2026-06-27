defmodule ControlPlaneWeb.VpsListLive do
  @moduledoc "Customer VPS list (replica of vps-frontend /dashboard/vps)."
  use ControlPlaneWeb, :live_view

  import ControlPlaneWeb.DashboardComponents, only: [vps_status_badge: 1]
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Events

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, load(socket)}
  end

  defp load(socket) do
    assign(socket, vpses: Fleet.list_vpses_for_owner(socket.assigns.current_user.id))
  end

  def handle_info({:fleet_changed, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Mijn VPS'en</h1>
          <p class="text-muted-foreground">Beheer en bekijk al je virtuele servers.</p>
        </div>
        <.link
          navigate="/dashboard/vps/new"
          class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110 active:scale-[0.97] transition-all"
        >
          <span class="material-symbols-outlined mr-2" style="font-size:18px">add_circle</span> Nieuwe VPS
        </.link>
      </div>

      <div :if={@vpses != []} class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <.link
          :for={v <- @vpses}
          navigate={~p"/dashboard/vps/#{v.id}"}
          class="block rounded-lg border bg-card text-card-foreground shadow-sm transition-shadow hover:shadow-md card-glow"
        >
          <div class="flex flex-row items-center justify-between space-y-0 p-6 pb-2">
            <div class="text-base font-semibold flex items-center gap-2">
              <span class="material-symbols-outlined text-muted-foreground" style="font-size:18px">dns</span>
              {v.name}
            </div>
            <.vps_status_badge status={v.status} />
          </div>
          <div class="p-6 pt-0">
            <div class="grid gap-2 text-sm text-muted-foreground">
              <div class="flex items-center gap-2">
                <span class="material-symbols-outlined" style="font-size:16px">public</span>
                <span>{v.ip_address || "Geen IP"}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="material-symbols-outlined" style="font-size:16px">memory</span>
                <span>{v.vcpu} vCPU &middot; {div(v.ram_mb, 1024)} GB RAM &middot; {v.disk_gb} GB</span>
              </div>
            </div>
          </div>
        </.link>
      </div>

      <div :if={@vpses == []} class="rounded-lg border bg-card text-card-foreground shadow-sm">
        <div class="flex flex-col items-center justify-center py-16">
          <span class="material-symbols-outlined text-muted-foreground mb-4" style="font-size:48px">dns</span>
          <h3 class="text-lg font-semibold mb-2">Geen VPS'en gevonden</h3>
          <p class="text-muted-foreground mb-6 text-center">Je hebt nog geen VPS'en. Vraag je eerste VPS aan!</p>
          <.link
            navigate="/dashboard/vps/new"
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110 transition-all"
          >
            <span class="material-symbols-outlined mr-2" style="font-size:18px">add_circle</span> Eerste VPS aanvragen
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
