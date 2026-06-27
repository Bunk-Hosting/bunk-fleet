defmodule ControlPlaneWeb.DashboardComponents do
  @moduledoc "Dashboard chrome (sidebar) — an exact replica of vps-frontend's sidebar."
  use ControlPlaneWeb, :html

  @main_nav [
    %{label: "Dashboard", href: "/dashboard", icon: "dashboard"},
    %{label: "Mijn VPS'en", href: "/dashboard/vps", icon: "dns"},
    %{label: "Nieuwe VPS", href: "/dashboard/vps/new", icon: "add_circle"},
    %{label: "Beveiliging", href: "/dashboard/beveiliging", icon: "verified_user"}
  ]
  @billing_nav [
    %{label: "Finance", href: "/dashboard/billing", icon: "credit_card"},
    %{label: "Facturen", href: "/dashboard/billing/invoices", icon: "receipt_long"}
  ]
  @admin_nav [
    %{label: "Admin", href: "/dashboard/beheer", icon: "shield"},
    %{label: "Gebruikers", href: "/dashboard/beheer/users", icon: "group"},
    %{label: "VPS Beheer", href: "/dashboard/beheer/vps", icon: "lan"},
    %{label: "Netwerk", href: "/dashboard/beheer/network", icon: "hub"},
    %{label: "Auditlogs", href: "/dashboard/beheer/logs", icon: "description"},
    %{label: "Reconciliatie", href: "/dashboard/beheer/reconcile", icon: "sync"}
  ]
  @admin_settings %{label: "Instellingen", href: "/dashboard/beheer/settings", icon: "settings"}

  attr :current_user, :map, required: true
  attr :current_path, :string, default: "/dashboard"

  def sidebar(assigns) do
    assigns =
      assign(assigns,
        main_nav: @main_nav,
        billing_nav: @billing_nav,
        admin_nav: @admin_nav,
        admin_settings: @admin_settings
      )

    ~H"""
    <aside class="hidden md:flex md:w-64 md:flex-col md:fixed md:inset-y-0 border-r bg-card z-20">
      <div class="flex h-full flex-col">
        <div class="px-4 py-6">
          <.link navigate="/dashboard" class="flex items-center gap-3">
            <span class="material-symbols-outlined text-accent" style="font-variation-settings:'FILL' 1">dns</span>
            <span class="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
          </.link>
        </div>
        <div class="h-px bg-border"></div>
        <nav class="flex-1 overflow-y-auto space-y-1 px-3 py-4">
          <p class="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Menu</p>
          <.nav_link
            :for={item <- @main_nav}
            item={item}
            current_path={@current_path}
            badge={item.href == "/dashboard/beveiliging" and is_nil(@current_user.totp_confirmed_at)}
          />
          <div class="h-px bg-border my-4"></div>
          <p class="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Finance</p>
          <.nav_link :for={item <- @billing_nav} item={item} current_path={@current_path} />
          <%= if @current_user.role == :admin do %>
            <div class="h-px bg-border my-4"></div>
            <p class="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Beheer</p>
            <.nav_link :for={item <- @admin_nav} item={item} current_path={@current_path} />
          <% end %>
        </nav>
        <div class="h-px bg-border"></div>
        <div class="px-3 py-4 space-y-1">
          <.nav_link :if={@current_user.role == :admin} item={@admin_settings} current_path={@current_path} />
          <div class="px-3 pt-2">
            <p class="text-sm font-medium">{@current_user.name || @current_user.email}</p>
            <p class="text-xs text-muted-foreground">{@current_user.email}</p>
          </div>
          <.link
            href={~p"/logout"}
            method="delete"
            class="flex w-full items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent/10 hover:text-accent transition-colors"
          >
            <span class="material-symbols-outlined" style="font-size:18px">logout</span> Uitloggen
          </.link>
        </div>
      </div>
    </aside>

    <div class="sticky top-0 z-40 flex items-center gap-4 border-b bg-background px-4 py-3 md:hidden">
      <.link navigate="/dashboard" class="flex items-center gap-3">
        <span class="material-symbols-outlined text-accent" style="font-variation-settings:'FILL' 1">dns</span>
        <span class="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
      </.link>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :current_path, :string, required: true
  attr :badge, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.href}
      class={[
        "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        (active?(@item.href, @current_path) && "bg-primary text-primary-foreground") ||
          "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
      ]}
    >
      <span class="material-symbols-outlined shrink-0" style="font-size:18px">{@item.icon}</span>
      <span class="flex-1">{@item.label}</span>
      <span :if={@badge} class="h-2 w-2 rounded-full bg-orange-500 shrink-0"></span>
    </.link>
    """
  end

  attr :status, :atom, required: true

  @doc "VPS status pill matching vps-frontend's StatusBadge."
  def vps_status_badge(assigns) do
    {label, cls} = badge_style(assigns.status)
    assigns = assign(assigns, label: label, cls: cls)

    ~H"""
    <span class={["inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold", @cls]}>
      {@label}
    </span>
    """
  end

  defp badge_style(:active), do: {"Actief", "border-transparent bg-green-500/15 text-green-400"}
  defp badge_style(:stopped), do: {"Gestopt", "border-transparent bg-secondary text-secondary-foreground"}
  defp badge_style(:paused), do: {"Gepauzeerd", "border-transparent bg-amber-500/15 text-amber-400"}
  defp badge_style(:queued), do: {"In wachtrij", "border-transparent bg-amber-500/15 text-amber-400"}
  defp badge_style(:provisioning), do: {"Wordt aangemaakt", "border-transparent bg-amber-500/15 text-amber-400"}
  defp badge_style(:failed), do: {"Fout", "border-transparent bg-destructive/15 text-destructive"}
  defp badge_style(:deleting), do: {"Wordt verwijderd", "border-transparent bg-amber-500/15 text-amber-400"}
  defp badge_style(:deleted), do: {"Verwijderd", "border text-muted-foreground"}
  defp badge_style(_), do: {"Onbekend", "border text-muted-foreground"}

  defp active?(href, path) do
    path = path || "/dashboard"
    cond do
      path == href -> true
      href == "/dashboard" -> false
      true -> String.starts_with?(path, href <> "/")
    end
  end
end
