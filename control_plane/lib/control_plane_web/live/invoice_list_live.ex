defmodule ControlPlaneWeb.InvoiceListLive do
  @moduledoc "Customer invoices (replica of vps-frontend /dashboard/billing/invoices). Invoicing engine: TODO."
  use ControlPlaneWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.link navigate={~p"/dashboard/billing"} class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
        <span class="material-symbols-outlined" style="font-size:18px">arrow_back</span> Terug
      </.link>
      <div>
        <h1 class="text-2xl font-bold tracking-tight">Facturen</h1>
        <p class="text-muted-foreground">Al je facturen op een rij.</p>
      </div>
      <div class="rounded-lg border bg-card text-card-foreground shadow-sm">
        <div class="p-6"><p class="text-sm text-muted-foreground text-center py-8">Nog geen facturen.</p></div>
      </div>
    </div>
    """
  end
end
