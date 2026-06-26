defmodule ControlPlaneWeb.PortalLive do
  @moduledoc "Customer portal: create and manage your own VPS servers."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.{Fleet, Provisioning}
  alias ControlPlane.Fleet.Events

  @sizes %{
    "small" => %{vcpu: 1, ram_mb: 1024, disk_gb: 10, label: "Small — 1 vCPU · 1 GB · 10 GB"},
    "medium" => %{vcpu: 2, ram_mb: 2048, disk_gb: 20, label: "Medium — 2 vCPU · 2 GB · 20 GB"},
    "large" => %{vcpu: 4, ram_mb: 4096, disk_gb: 40, label: "Large — 4 vCPU · 4 GB · 40 GB"}
  }

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(regions: Fleet.list_regions(), sizes: @sizes) |> load_vpses() |> assign_wallet()}
  end

  def handle_info({:fleet_changed, _kind}, socket), do: {:noreply, load_vpses(socket)}

  def handle_event("create", %{"name" => name, "region_code" => code, "size" => size}, socket) do
    spec = Map.get(@sizes, size, @sizes["small"])

    attrs =
      case Fleet.region_by_code(code) do
        %{id: region_id} -> %{region_id: region_id, name: name, vcpu: spec.vcpu, ram_mb: spec.ram_mb, disk_gb: spec.disk_gb}
        _ -> nil
      end

    cond do
      attrs == nil ->
        {:noreply, put_flash(socket, :error, "Kies een geldige regio.")}

      String.trim(name) == "" ->
        {:noreply, put_flash(socket, :error, "Geef je VPS een naam.")}

      true ->
        user = socket.assigns.current_user
        price = ControlPlane.Credits.price_for_size(size) || 0

        case ControlPlane.Credits.charge(user.id, price, "vps_charge", "VPS #{size} · #{code}") do
          {:error, :insufficient_credits} ->
            {:noreply,
             put_flash(socket, :error, "Onvoldoende tegoed — een #{size} kost #{eur(price)}/mnd. Vul je tegoed aan.")}

          {:ok, _charge} ->
            case Provisioning.create_vps_for_owner(user, attrs) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "VPS wordt aangemaakt — #{eur(price)} afgeschreven.")
                 |> load_vpses()
                 |> assign_wallet()}

              {:error, reason} ->
                ControlPlane.Credits.refund(user.id, price, "vps_refund", "Terugbetaling: aanmaken mislukt")
                {:noreply, socket |> put_flash(:error, create_error(reason)) |> assign_wallet()}
            end
        end
    end
  end


  def handle_event(action, %{"id" => id}, socket) when action in ~w(start stop pause resume delete) do
    user = socket.assigns.current_user

    with %{} <- Fleet.get_vps_for_owner(user.id, id),
         {:ok, _} <- apply_action(action, id) do
      {:noreply, socket |> put_flash(:info, "Verzoek ingediend.") |> load_vpses()}
    else
      nil -> {:noreply, put_flash(socket, :error, "Niet gevonden.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Actie niet toegestaan in deze status.")}
    end
  end

  defp apply_action("start", id), do: Provisioning.start_vps(id)
  defp apply_action("stop", id), do: Provisioning.stop_vps(id)
  defp apply_action("pause", id), do: Provisioning.pause_vps(id)
  defp apply_action("resume", id), do: Provisioning.resume_vps(id)
  defp apply_action("delete", id), do: Provisioning.delete_vps(id)

  defp load_vpses(socket) do
    assign(socket, vpses: Fleet.list_vpses_for_owner(socket.assigns.current_user.id))
  end

  defp create_error(:quota_exceeded), do: "Je hebt je maximum aantal VPS-servers bereikt."
  defp create_error(:no_capacity), do: "Geen capaciteit beschikbaar in die regio."
  defp create_error(:pool_exhausted), do: "Geen IP-adressen meer beschikbaar."
  defp create_error(_), do: "Kon de VPS niet aanmaken."

  defp eur(cents), do: "€" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp assign_wallet(socket) do
    uid = socket.assigns.current_user.id
    assign(socket,
      balance_cents: ControlPlane.Credits.balance_cents(uid),
      ledger: ControlPlane.Credits.list_entries(uid, 8)
    )
  end

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div>
          <h1>Mijn VPS-servers</h1>
          <p class="muted">Ingelogd als {@current_user.email}</p>
        </div>
        <span class="badge">Tegoed: {eur(@balance_cents)}</span>
        <.link navigate={~p"/app/security"} class="badge">Beveiliging</.link>
        <.link navigate={~p"/app/host"} class="badge">Word host</.link>
        <.link href={~p"/logout"} method="delete" class="badge">Uitloggen</.link>
      </div>

      <p :if={@flash["info"]} class="flash-info">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={@flash["error"]} class="flash-err">{Phoenix.Flash.get(@flash, :error)}</p>

      <h2>Nieuwe VPS</h2>
      <form phx-submit="create" class="create-form">
        <input type="text" name="name" placeholder="naam (bv. web-1)" required />
        <select name="region_code">
          <option :for={r <- @regions} value={r.code}>{r.name}</option>
        </select>
        <select name="size">
          <option :for={{k, s} <- @sizes} value={k}>{s.label} — {eur(ControlPlane.Credits.price_for_size(k))}/mnd</option>
        </select>
        <button type="submit">Aanmaken</button>
      </form>

      <h2>Tegoed</h2>
      <p class="muted">Saldo: <strong>{eur(@balance_cents)}</strong></p>
      <div class="table-wrap">
        <table>
          <tbody>
            <tr :for={e <- @ledger}>
              <td class="muted">{Calendar.strftime(e.inserted_at, "%d-%m %H:%M")}</td>
              <td>{e.description}</td>
              <td style={"text-align:right;color:" <> if(e.amount_cents >= 0, do: "#7ee2a8", else: "#e6edf3")}>{eur(e.amount_cents)}</td>
            </tr>
            <tr :if={@ledger == []}>
              <td class="muted" colspan="3">Nog geen boekingen.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2>Servers</h2>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Naam</th><th>Status</th><th>IP</th><th>Specs</th><th>Acties</th></tr></thead>
          <tbody>
            <tr :for={v <- @vpses}>
              <td>{v.name}</td>
              <td><span class={"dot " <> dot(v.status)}></span><span class="status">{label(v.status)}</span></td>
              <td class="mono">{v.ip_address || "—"}</td>
              <td class="muted">{v.vcpu} vCPU · {v.ram_mb} MB · {v.disk_gb} GB</td>
              <td>
                <button :if={v.status == :stopped} phx-click="start" phx-value-id={v.id} class="btn">Start</button>
                <button :if={v.status in [:active, :paused]} phx-click="stop" phx-value-id={v.id} class="btn">Stop</button>
                <button :if={v.status == :active} phx-click="pause" phx-value-id={v.id} class="btn">Pauze</button>
                <button :if={v.status == :paused} phx-click="resume" phx-value-id={v.id} class="btn">Hervat</button>
                <button :if={v.status in [:active, :stopped, :paused, :failed]} phx-click="delete" phx-value-id={v.id}
                  data-confirm="Deze VPS verwijderen?" class="btn btn-danger">Verwijder</button>
              </td>
            </tr>
            <tr :if={@vpses == []}><td colspan="5" class="empty">Nog geen VPS-servers. Maak er hierboven een aan.</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <style>
      .create-form { display:flex; gap:10px; flex-wrap:wrap; margin: 10px 0 4px; }
      .create-form input, .create-form select { padding:9px 11px; background:#0b0f14; border:1px solid #2d3540; border-radius:8px; color:#e6edf3; font-size:13px; }
      .create-form button { padding:9px 18px; background:#2563eb; border:none; border-radius:8px; color:#fff; font-weight:600; cursor:pointer; }
      .btn { padding:5px 12px; margin-right:6px; background:#21262d; border:1px solid #2d3540; border-radius:7px; color:#e6edf3; font-size:12px; cursor:pointer; }
      .btn:hover { background:#2d333b; }
      .btn-danger { color:#ff9b9b; border-color:#5c2228; }
      .flash-info { background:#0d2818; border:1px solid #1c5235; color:#7ee2a8; padding:9px 12px; border-radius:8px; }
      .flash-err { background:#2d1417; border:1px solid #5c2228; color:#ff9b9b; padding:9px 12px; border-radius:8px; }
      .dot.blue { background:#3081f7; } .dot.purple { background:#a371f7; }
    </style>
    """
  end

  defp dot(:active), do: "green"
  defp dot(:stopped), do: "grey"
  defp dot(:paused), do: "amber"
  defp dot(s) when s in [:provisioning, :queued, :deleting], do: "blue"
  defp dot(_), do: "grey"

  defp label(:active), do: "Actief"
  defp label(:stopped), do: "Gestopt"
  defp label(:paused), do: "Gepauzeerd"
  defp label(:provisioning), do: "Wordt aangemaakt"
  defp label(:queued), do: "In wachtrij"
  defp label(:deleting), do: "Wordt verwijderd"
  defp label(:failed), do: "Mislukt"
  defp label(other), do: to_string(other)
end
