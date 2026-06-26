defmodule ControlPlaneWeb.ConsoleLive do
  @moduledoc "In-browser SSH console for a customer's own VPS."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Fleet
  alias ControlPlane.Console.Session

  def mount(%{"id" => id}, _session, socket) do
    case Fleet.get_vps_for_owner(socket.assigns.current_user.id, id) do
      nil ->
        {:ok, socket |> put_flash(:error, "VPS niet gevonden.") |> redirect(to: ~p"/app")}

      vps ->
        socket = assign(socket, vps: vps, status: :connecting, session_pid: nil)
        {:ok, if(connected?(socket), do: start_session(socket), else: socket)}
    end
  end

  @max_sessions_per_user 3

  defp start_session(socket) do
    vps = socket.assigns.vps
    uid = socket.assigns.current_user.id

    cond do
      vps.status != :active or is_nil(vps.ip_address) ->
        assign(socket, status: :unavailable)

      session_count(uid) >= @max_sessions_per_user ->
        assign(socket, status: :too_many)

      true ->
        user = (Application.get_env(:control_plane, :console) || [])[:ssh_user] || "root"

        case Session.start_link(%{host: vps.ip_address, port: 22, user: user, owner: self(), user_id: uid}) do
          {:ok, pid} -> assign(socket, status: :connected, session_pid: pid)
          _ -> assign(socket, status: :error)
        end
    end
  end

  defp session_count(uid) do
    length(Registry.lookup(ControlPlane.Console.Registry, {:user, uid}))
  end

  def handle_event("input", %{"data" => data}, socket) do
    if socket.assigns.session_pid, do: Session.send_input(socket.assigns.session_pid, data)
    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.session_pid, do: Session.resize(socket.assigns.session_pid, cols, rows)
    {:noreply, socket}
  end

  def handle_info({:console_output, data}, socket) do
    {:noreply, push_event(socket, "output", %{data: Base.encode64(data)})}
  end

  def handle_info({:console_closed, _reason}, socket) do
    {:noreply, socket |> assign(status: :closed) |> push_event("closed", %{})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="cwrap">
      <div class="hdr">
        <div>
          <h1>Console — {@vps.name}</h1>
          <p class="muted">{@vps.ip_address} · {@vps.status}</p>
        </div>
        <.link navigate={~p"/app"} class="badge">← Mijn servers</.link>
      </div>

      <%= case @status do %>
        <% s when s in [:connecting, :connected, :closed] -> %>
          <div id="terminal" phx-hook="Terminal" phx-update="ignore" class="term"></div>
        <% :unavailable -> %>
          <p class="muted">De console is alleen beschikbaar voor een actieve VPS met een IP-adres.</p>
        <% :too_many -> %>
          <p class="muted">Je hebt te veel console-sessies open. Sluit er een en probeer opnieuw.</p>
        <% _ -> %>
          <p class="muted">Kon geen verbinding maken met de console. Probeer het later opnieuw.</p>
      <% end %>
    </div>

    <style>
      .cwrap { max-width: 1100px; margin: 0 auto; padding: 18px 16px; }
      .hdr { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:10px; }
      .badge { font-size:12px; color:#8c90a1; text-decoration:none; border:1px solid #333539; padding:5px 10px; border-radius:7px; }
      h1 { font-size:18px; margin:0 0 2px; }
      .muted { color:#8c90a1; font-size:13px; }
      .term { height: 70vh; background:#0c0e12; border:1px solid #333539; border-radius:10px; padding:8px; }
    </style>
    """
  end
end
