defmodule ControlPlaneWeb.PortalLive do
  @moduledoc "Customer portal: a logged-in user's own VPS servers."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Fleet

  def mount(_params, _session, socket) do
    vpses = Fleet.list_vpses_for_owner(socket.assigns.current_user.id)
    {:ok, assign(socket, vpses: vpses)}
  end

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div>
          <h1>Mijn VPS-servers</h1>
          <p class="muted">Ingelogd als {@current_user.email}</p>
        </div>
        <.link href={~p"/logout"} method="delete" class="badge">Uitloggen</.link>
      </div>

      <div class="table-wrap" style="margin-top:16px">
        <table>
          <thead><tr><th>Naam</th><th>Status</th><th>IP-adres</th><th>vCPU</th><th>RAM</th><th>Schijf</th></tr></thead>
          <tbody>
            <tr :for={v <- @vpses}>
              <td>{v.name}</td>
              <td class="status">{v.status}</td>
              <td class="mono">{v.ip_address || "—"}</td>
              <td>{v.vcpu}</td>
              <td>{v.ram_mb} MB</td>
              <td>{v.disk_gb} GB</td>
            </tr>
            <tr :if={@vpses == []}><td colspan="6" class="empty">Nog geen VPS-servers. Maak er een aan.</td></tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
