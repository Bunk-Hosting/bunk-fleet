defmodule ControlPlaneWeb.HostLive do
  @moduledoc "Portal: become a host — generate an enroll token + show the installer."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.{Accounts, Enrollment, Fleet}

  def mount(_params, _session, socket) do
    # Becoming a host makes you an operator (a superset of :user).
    user = socket.assigns.current_user
    if user.role == :user, do: Accounts.update_user_role(user, :operator)

    {:ok, assign(socket, regions: Fleet.list_regions(), token: nil, region_code: nil)}
  end

  def handle_event("generate", %{"region_code" => code}, socket) do
    case Fleet.region_by_code(code) do
      %{id: region_id} ->
        {:ok, {token, _}} =
          Enrollment.create_enroll_token_for_operator(socket.assigns.current_user, %{
            region_id: region_id,
            tier: :community,
            ttl_seconds: 3600
          })

        {:noreply, assign(socket, token: token, region_code: code)}

      _ ->
        {:noreply, put_flash(socket, :error, "Kies een geldige regio.")}
    end
  end

  defp cp_url, do: Application.get_env(:control_plane, :public_url) || "https://control.bunkhosting.nl"

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div>
          <h1>Word host</h1>
          <p class="muted">Bied je eigen hardware aan en verdien aan VPS-hosting.</p>
        </div>
        <.link navigate={~p"/app"} class="badge">← Mijn servers</.link>
      </div>

      <h2>Zo werkt het</h2>
      <ol class="muted" style="line-height:1.9">
        <li>Kies een regio en genereer hieronder je enroll-token.</li>
        <li>Draai het install-commando als root op je Proxmox-host.</li>
        <li>De wizard vraagt je hypervisor-gegevens en verbindt automatisch met Bunk.</li>
        <li>Je node verschijnt online en krijgt VPS-servers toegewezen.</li>
      </ol>

      <h2>1. Genereer je token</h2>
      <form phx-submit="generate" class="create-form">
        <select name="region_code">
          <option :for={r <- @regions} value={r.code}>{r.name}</option>
        </select>
        <button type="submit">Genereer install-commando</button>
      </form>

      <%= if @token do %>
        <h2>2. Draai dit op je Proxmox-host (als root)</h2>
        <pre class="cmd">curl -fsSL {cp_url()}/install.sh | bash -s -- --token {@token}</pre>
        <p class="muted">Geldig 1 uur · regio <span class="mono">{@region_code}</span>. De wizard vraagt je Proxmox API-host, node en token.</p>
      <% end %>
    </div>

    <style>
      .create-form { display:flex; gap:10px; flex-wrap:wrap; margin: 8px 0; }
      .create-form select { padding:9px 11px; background:#0c0e12; border:1px solid #333539; border-radius:8px; color:#e2e2e8; }
      .create-form button { padding:9px 18px; background:#006af2; border:none; border-radius:8px; color:#fff; font-weight:600; cursor:pointer; }
      pre.cmd { background:#0c0e12; border:1px solid #333539; border-radius:8px; padding:14px; overflow-x:auto; font-family:ui-monospace,monospace; font-size:13px; color:#7ee2a8; }
    </style>
    """
  end
end
