defmodule ControlPlaneWeb.SecurityLive do
  @moduledoc "Account security / 2FA (replica of vps-frontend /dashboard/beveiliging)."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Accounts

  def mount(_params, _session, socket), do: {:ok, assign_state(socket, false, false)}

  defp assign_state(socket, setup, disabling) do
    user = Accounts.get_user!(socket.assigns.current_user.id)
    assign(socket, user: user, setup: setup, disabling: disabling, error: nil)
  end

  def handle_event("enable", _params, socket) do
    user = Accounts.start_totp_setup(socket.assigns.user)
    {:noreply, assign(socket, user: user, setup: true, error: nil)}
  end

  def handle_event("confirm", %{"code" => code}, socket) do
    case Accounts.confirm_totp(socket.assigns.user, code) do
      {:ok, user} ->
        {:noreply, socket |> assign(user: user, setup: false, error: nil) |> put_flash(:info, "TOTP ingeschakeld. Je account is nu beveiligd met een authenticator-app.")}

      {:error, _} ->
        {:noreply, assign(socket, error: "De ingevoerde code klopt niet. Probeer opnieuw.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:ok, _} = Accounts.disable_totp(socket.assigns.user)
    {:noreply, assign_state(socket, false, false)}
  end

  def handle_event("start_disable", _params, socket), do: {:noreply, assign(socket, disabling: true, error: nil)}
  def handle_event("stop_disable", _params, socket), do: {:noreply, assign(socket, disabling: false, error: nil)}

  def handle_event("disable", %{"code" => code}, socket) do
    if Accounts.valid_totp?(socket.assigns.user, code) do
      {:ok, _} = Accounts.disable_totp(socket.assigns.user)
      {:noreply, socket |> assign_state(false, false) |> put_flash(:info, "Twee-factor-authenticatie is verwijderd.")}
    else
      {:noreply, assign(socket, error: "De ingevoerde code klopt niet.")}
    end
  end

  defp active?(user), do: not is_nil(user.totp_confirmed_at)
  defp qr_svg(uri), do: uri |> EQRCode.encode() |> EQRCode.svg(width: 192) |> Phoenix.HTML.raw()

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <div>
        <h1 class="text-2xl font-display font-bold">Beveiliging</h1>
        <p class="text-muted-foreground mt-1">Beheer twee-factor-authenticatie voor je account.</p>
      </div>

      <div :if={not active?(@user) and not @setup} class="rounded-lg border border-primary/30 bg-primary/5 p-4">
        <p class="font-semibold text-sm">Beveilig je account met een authenticator-app</p>
        <p class="text-sm text-muted-foreground mt-0.5">
          Scan de QR-code met Google Authenticator, Authy of een andere TOTP-app. Hierna heb je naast je wachtwoord altijd een unieke code nodig om in te loggen.
        </p>
      </div>

      <p :if={@error} class="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-2 text-sm text-destructive">{@error}</p>

      <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
        <div class="p-6">
          <div class="flex items-start justify-between gap-4">
            <div class="flex gap-3">
              <span class="material-symbols-outlined text-accent">{if active?(@user), do: "verified_user", else: "shield"}</span>
              <div>
                <p class="font-semibold">Authenticator-app (TOTP)</p>
                <p class="text-sm text-muted-foreground">
                  {if active?(@user), do: "Je account is beveiligd met een authenticator-app.", else: "Voeg een extra beveiligingslaag toe met een authenticator-app."}
                </p>
              </div>
            </div>
            <span class={[
              "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold shrink-0",
              (active?(@user) && "border-transparent bg-green-500/15 text-green-400") || "border-transparent bg-secondary text-secondary-foreground"
            ]}>
              {if active?(@user), do: "Ingeschakeld", else: "Uitgeschakeld"}
            </span>
          </div>

          <div class="mt-4">
            <button :if={not active?(@user) and not @setup} phx-click="enable"
              class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110 transition-all">
              <span class="material-symbols-outlined mr-2" style="font-size:18px">add_moderator</span> TOTP inschakelen
            </button>

            <button :if={active?(@user) and not @disabling} phx-click="start_disable"
              class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-medium bg-destructive text-destructive-foreground hover:bg-destructive/90 transition-all">
              TOTP uitschakelen
            </button>

            <form :if={active?(@user) and @disabling} phx-submit="disable" class="flex flex-wrap items-end gap-2">
              <div class="space-y-1">
                <label class="text-xs text-muted-foreground">Voer een code in om uit te schakelen</label>
                <input name="code" inputmode="numeric" maxlength="6" placeholder="123456" required
                  class="flex h-10 w-40 rounded-md border border-input bg-background px-3 py-2 text-center tracking-widest focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring" />
              </div>
              <button type="submit" class="inline-flex items-center justify-center h-10 px-4 rounded-md text-sm font-medium bg-destructive text-destructive-foreground hover:bg-destructive/90">Uitschakelen</button>
              <button type="button" phx-click="stop_disable" class="inline-flex items-center justify-center h-10 px-4 rounded-md text-sm font-medium border border-primary/40 hover:bg-primary/10">Annuleren</button>
            </form>
          </div>
        </div>
      </div>

      <div :if={@setup} class="rounded-lg border bg-card text-card-foreground shadow-sm p-6 space-y-4">
        <p class="text-sm text-muted-foreground">Scan de QR-code met je authenticator-app (Google Authenticator, Authy, Bitwarden, etc.).</p>
        <div class="flex justify-center">
          <div class="bg-white p-2 rounded-lg">{qr_svg(Accounts.totp_uri(@user))}</div>
        </div>
        <p class="text-xs text-muted-foreground">Kun je de QR-code niet scannen? Voer deze sleutel handmatig in:</p>
        <code class="block bg-muted rounded px-3 py-2 text-xs font-mono break-all">{Accounts.totp_secret_base32(@user)}</code>
        <form phx-submit="confirm" class="flex flex-wrap items-end gap-2">
          <div class="space-y-1">
            <label class="text-xs text-muted-foreground">Bevestig met een code uit de app</label>
            <input name="code" inputmode="numeric" maxlength="6" placeholder="123456" required autofocus
              class="flex h-10 w-40 rounded-md border border-input bg-background px-3 py-2 text-center tracking-widest focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring" />
          </div>
          <button type="submit" class="inline-flex items-center justify-center h-10 px-4 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110">Bevestigen</button>
          <button type="button" phx-click="cancel" class="inline-flex items-center justify-center h-10 px-4 rounded-md text-sm font-medium border border-primary/40 hover:bg-primary/10">Annuleren</button>
        </form>
      </div>
    </div>
    """
  end
end
