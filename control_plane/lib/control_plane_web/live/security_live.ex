defmodule ControlPlaneWeb.SecurityLive do
  @moduledoc "Portal security settings — enable/disable TOTP two-factor auth."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Accounts

  def mount(_params, _session, socket), do: {:ok, assign_user(socket, false)}

  defp assign_user(socket, setup) do
    user = Accounts.get_user!(socket.assigns.current_user.id)
    assign(socket, user: user, setup: setup, error: nil)
  end

  def handle_event("enable", _params, socket) do
    user = Accounts.start_totp_setup(socket.assigns.user)
    {:noreply, assign(socket, user: user, setup: true, error: nil)}
  end

  def handle_event("confirm", %{"code" => code}, socket) do
    case Accounts.confirm_totp(socket.assigns.user, code) do
      {:ok, user} ->
        {:noreply, socket |> assign(user: user, setup: false, error: nil) |> put_flash(:info, "Twee-factor is ingeschakeld.")}

      {:error, _} ->
        {:noreply, assign(socket, error: "Ongeldige code — controleer je authenticator-app en probeer opnieuw.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:ok, _} = Accounts.disable_totp(socket.assigns.user)
    {:noreply, assign_user(socket, false)}
  end

  def handle_event("disable", _params, socket) do
    {:ok, _} = Accounts.disable_totp(socket.assigns.user)
    {:noreply, socket |> assign_user(false) |> put_flash(:info, "Twee-factor is uitgeschakeld.")}
  end

  defp qr_svg(uri), do: uri |> EQRCode.encode() |> EQRCode.svg(width: 200) |> Phoenix.HTML.raw()

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <div class="hdr">
        <h1>Beveiliging</h1>
        <.link navigate={~p"/app"} class="badge">← Mijn servers</.link>
      </div>

      <p :if={@flash["info"]} class="flash-info">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={@error} class="flash-err">{@error}</p>

      <h2>Twee-factor-authenticatie</h2>
      <%= cond do %>
        <% Accounts.totp_active?(@user) -> %>
          <p class="ok">✓ Twee-factor is <strong>actief</strong> op je account.</p>
          <button class="danger" phx-click="disable" data-confirm="Twee-factor-authenticatie uitschakelen?">
            Uitschakelen
          </button>
        <% @setup -> %>
          <p class="muted">Scan deze QR-code met Google Authenticator, 1Password, Authy of een andere app:</p>
          <div class="qr">{qr_svg(Accounts.totp_uri(@user))}</div>
          <p class="muted">Of voer de sleutel handmatig in:<br /><code>{Accounts.totp_secret_base32(@user)}</code></p>
          <form phx-submit="confirm" class="codeform">
            <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code"
                   maxlength="6" placeholder="6-cijferige code" />
            <button type="submit">Bevestigen</button>
            <button type="button" class="ghost" phx-click="cancel">Annuleren</button>
          </form>
        <% true -> %>
          <p class="muted">Bescherm je account met een extra eenmalige code bij het inloggen.</p>
          <button phx-click="enable">Twee-factor inschakelen</button>
      <% end %>
    </div>

    <style>
      .wrap { max-width: 760px; margin: 0 auto; padding: 28px 20px; }
      .hdr { display:flex; justify-content:space-between; align-items:center; }
      .badge { font-size:12px; color:#8b949e; text-decoration:none; border:1px solid #2d3540; padding:5px 10px; border-radius:7px; }
      h2 { font-size:16px; margin-top:22px; }
      .muted { color:#8b949e; font-size:13px; line-height:1.7; }
      .ok { color:#7ee2a8; }
      code { background:#0b0f14; border:1px solid #2d3540; border-radius:6px; padding:3px 7px; font-size:13px; }
      .qr { background:#fff; display:inline-block; padding:10px; border-radius:10px; margin:10px 0; }
      .codeform { display:flex; gap:10px; flex-wrap:wrap; margin-top:12px; }
      .codeform input { padding:10px 12px; background:#0b0f14; border:1px solid #2d3540; border-radius:8px; color:#e6edf3; font-size:16px; letter-spacing:3px; text-align:center; }
      button { padding:9px 18px; background:#2563eb; border:none; border-radius:8px; color:#fff; font-weight:600; cursor:pointer; font-size:13px; }
      button.danger { background:#b91c1c; }
      button.ghost { background:#21262d; border:1px solid #2d3540; }
      .flash-info { background:#0f2417; border:1px solid #1c5236; color:#7ee2a8; padding:9px 12px; border-radius:8px; font-size:13px; }
      .flash-err { background:#2d1417; border:1px solid #5c2228; color:#ff9b9b; padding:9px 12px; border-radius:8px; font-size:13px; }
    </style>
    """
  end
end
