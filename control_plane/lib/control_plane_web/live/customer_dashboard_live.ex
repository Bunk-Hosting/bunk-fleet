defmodule ControlPlaneWeb.CustomerDashboardLive do
  @moduledoc "Customer dashboard overview (replica of vps-frontend /dashboard)."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Fleet

  def mount(_params, _session, socket) do
    {:ok, assign_stats(socket)}
  end

  defp assign_stats(socket) do
    vpses = Fleet.list_vpses_for_owner(socket.assigns.current_user.id)
    assign(socket,
      vps_total: length(vpses),
      vps_active: Enum.count(vpses, &(&1.status == :active)),
      vpses: Enum.take(vpses, 5)
    )
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h1 class="text-3xl font-bold">Dashboard</h1>
        <p class="text-muted-foreground">Welkom terug, {@current_user.name || @current_user.email}.</p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm card-glow">
          <div class="flex flex-row items-center justify-between p-6 pb-2">
            <p class="text-sm font-medium text-muted-foreground">Totaal VPS'en</p>
            <span class="material-symbols-outlined text-accent">dns</span>
          </div>
          <div class="p-6 pt-0"><div class="text-2xl font-bold">{@vps_total}</div></div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm card-glow">
          <div class="flex flex-row items-center justify-between p-6 pb-2">
            <p class="text-sm font-medium text-muted-foreground">Actief</p>
            <span class="material-symbols-outlined text-green-500">check_circle</span>
          </div>
          <div class="p-6 pt-0"><div class="text-2xl font-bold text-green-500">{@vps_active}</div></div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm card-glow">
          <div class="flex flex-row items-center justify-between p-6 pb-2">
            <p class="text-sm font-medium text-muted-foreground">Nieuwe VPS</p>
            <span class="material-symbols-outlined text-accent">add_circle</span>
          </div>
          <div class="p-6 pt-0">
            <.link navigate="/dashboard/vps/new" class="text-sm text-primary underline-offset-4 hover:underline">Server aanmaken →</.link>
          </div>
        </div>
      </div>

      <div>
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-xl font-semibold">Recente VPS'en</h2>
          <.link navigate="/dashboard/vps" class="text-sm text-primary underline-offset-4 hover:underline">Alles bekijken</.link>
        </div>
        <div class="rounded-lg border bg-card overflow-hidden">
          <table class="w-full text-sm">
            <thead class="text-muted-foreground">
              <tr class="border-b border-border">
                <th class="text-left font-medium px-4 py-3">Naam</th>
                <th class="text-left font-medium px-4 py-3">Status</th>
                <th class="text-left font-medium px-4 py-3">IP</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={v <- @vpses} class="border-b border-border last:border-0">
                <td class="px-4 py-3 font-medium">{v.name}</td>
                <td class="px-4 py-3">{v.status}</td>
                <td class="px-4 py-3 font-mono text-xs text-muted-foreground">{v.ip_address || "—"}</td>
              </tr>
              <tr :if={@vpses == []}><td colspan="3" class="px-4 py-6 text-center text-muted-foreground">Nog geen VPS'en. <.link navigate="/dashboard/vps/new" class="text-primary hover:underline">Maak je eerste server.</.link></td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
