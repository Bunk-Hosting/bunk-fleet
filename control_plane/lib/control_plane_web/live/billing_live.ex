defmodule ControlPlaneWeb.BillingLive do
  @moduledoc "Customer finance overview (replica of vps-frontend /dashboard/billing)."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Subscriptions

  def mount(_params, _session, socket) do
    uid = socket.assigns.current_user.id

    {:ok,
     assign(socket,
       monthly: Subscriptions.monthly_total(uid),
       active: Subscriptions.active_count(uid),
       next_date: Subscriptions.next_billing_date(uid)
     )}
  end

  defp euro(d), do: "€" <> String.replace(Decimal.to_string(Decimal.round(d, 2)), ".", ",")
  defp fmt_date(nil), do: "—"
  defp fmt_date(d), do: Calendar.strftime(d, "%d-%m-%Y")

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">Finance</h1>
        <p class="text-muted-foreground">Bekijk je abonnementen, kosten en facturen.</p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6 pb-2"><div class="text-sm font-medium text-muted-foreground">Openstaande facturen</div></div>
          <div class="p-6 pt-0"><p class="text-2xl font-bold">0</p><p class="text-xs text-muted-foreground mt-1">0 openstaande facturen</p></div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6 pb-2"><div class="text-sm font-medium text-muted-foreground">Maandelijkse kosten</div></div>
          <div class="p-6 pt-0"><p class="text-2xl font-bold">{euro(@monthly)}</p><p class="text-xs text-muted-foreground mt-1">{@active} actieve VPS{if @active != 1, do: "'en", else: ""}</p></div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6 pb-2"><div class="text-sm font-medium text-muted-foreground">Volgende factuur</div></div>
          <div class="p-6 pt-0"><p class="text-2xl font-bold">{fmt_date(@next_date)}</p></div>
        </div>
        <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
          <div class="flex flex-col space-y-1.5 p-6 pb-2"><div class="text-sm font-medium text-muted-foreground">Actieve VPS</div></div>
          <div class="p-6 pt-0"><p class="text-2xl font-bold">{@active}</p></div>
        </div>
      </div>

      <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
        <div class="flex flex-row items-center justify-between p-6">
          <div class="text-lg font-semibold tracking-tight">Recente facturen</div>
          <.link navigate={~p"/dashboard/billing/invoices"} class="text-sm text-primary hover:underline">Alle facturen bekijken</.link>
        </div>
        <div class="p-6 pt-0">
          <p class="text-sm text-muted-foreground text-center py-8">Nog geen facturen.</p>
        </div>
      </div>
    </div>
    """
  end
end
