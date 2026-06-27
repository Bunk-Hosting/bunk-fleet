defmodule ControlPlaneWeb.VpsNewLive do
  @moduledoc "Customer VPS create — package picker (replica of vps-frontend /dashboard/vps/new)."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.{Fleet, Provisioning}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       packages: Fleet.list_available_packages(),
       selected: nil,
       label: "",
       error: nil,
       submitting: false
     )}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected: String.to_integer(id), error: nil)}
  end

  def handle_event("label", %{"label" => label}, socket) do
    {:noreply, assign(socket, label: String.replace(label, ~r/\s+/, "-"))}
  end

  def handle_event("create", params, socket) do
    label = Map.get(params, "label", socket.assigns.label)

    cond do
      is_nil(socket.assigns.selected) ->
        {:noreply, assign(socket, error: "Kies een VPS pakket om verder te gaan.")}

      true ->
        pkg = Fleet.get_package(socket.assigns.selected)
        region = Fleet.default_region()

        attrs = %{
          region_id: region.id,
          name: vps_name(label),
          vcpu: pkg.cpu_cores,
          ram_mb: pkg.ram_gb * 1024,
          disk_gb: pkg.disk_gb,
          template_id: pkg.template_id,
          package_id: pkg.id
        }

        case Provisioning.create_vps_for_owner(socket.assigns.current_user, attrs) do
          {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/dashboard/vps")}
          {:error, reason} -> {:noreply, assign(socket, error: create_error(reason))}
        end
    end
  end

  defp vps_name(label) do
    case String.trim(label || "") do
      "" -> "vps-" <> Integer.to_string(System.unique_integer([:positive]))
      n -> n
    end
  end

  defp create_error(:quota_exceeded), do: "Je hebt je maximum aantal VPS-servers bereikt."
  defp create_error(:no_capacity), do: "Geen capaciteit beschikbaar. Probeer het later opnieuw."
  defp create_error(:pool_exhausted), do: "Geen IP-adressen meer beschikbaar."
  defp create_error(_), do: "Kon VPS niet aanvragen. Probeer het opnieuw."

  defp price(p), do: "€" <> String.replace(Decimal.to_string(Decimal.round(p.price_monthly, 2)), ".", ",")

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl space-y-8">
      <div>
        <h1 class="text-3xl font-bold tracking-tight">Nieuwe VPS Aanvragen</h1>
        <p class="text-muted-foreground">Kies een pakket en geef je VPS optioneel een naam.</p>
      </div>

      <p :if={@error} class="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-2 text-sm text-destructive">{@error}</p>

      <div class="space-y-4">
        <h2 class="text-xl font-semibold">Kies een pakket</h2>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <button
            :for={pkg <- @packages}
            type="button"
            phx-click="select"
            phx-value-id={pkg.id}
            class={[
              "text-left rounded-lg border bg-card text-card-foreground shadow-sm transition-all",
              (@selected == pkg.id && "border-primary ring-2 ring-primary") || "hover:border-primary/50"
            ]}
          >
            <div class="flex flex-col space-y-1.5 p-6 pb-3">
              <div class="flex items-center justify-between">
                <div class="text-lg font-semibold leading-none tracking-tight">{pkg.name}</div>
                <span :if={@selected == pkg.id} class="material-symbols-outlined text-primary">check</span>
              </div>
              <div class="text-sm text-muted-foreground">{pkg.description}</div>
            </div>
            <div class="p-6 pt-0">
              <div class="space-y-1 text-sm">
                <p>{pkg.cpu_cores} vCPU</p>
                <p>{pkg.ram_gb} GB RAM</p>
                <p>{pkg.disk_gb} GB NVMe opslag</p>
                <p>{pkg.bandwidth_tb} TB bandbreedte</p>
              </div>
              <p class="mt-3 text-lg font-bold text-primary">{price(pkg)}/maand</p>
            </div>
          </button>
        </div>
      </div>

      <form phx-submit="create" class="space-y-8">
        <div class="space-y-4">
          <h2 class="text-xl font-semibold">Naam (optioneel)</h2>
          <div class="max-w-sm space-y-2">
            <label for="label" class="text-sm font-medium leading-none">Naam voor je VPS</label>
            <input
              id="label"
              name="label"
              value={@label}
              phx-change="label"
              placeholder="bijv. webserver of mijn-database"
              class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
            <p class="text-xs text-muted-foreground">Alleen letters, cijfers, koppeltekens en underscores. Geen spaties.</p>
          </div>
        </div>

        <div class="flex gap-4">
          <button type="submit" disabled={@submitting}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-semibold bg-gradient-to-r from-primary to-accent text-primary-foreground hover:brightness-110 active:scale-[0.97] transition-all disabled:opacity-50">
            VPS Aanvragen
          </button>
          <.link navigate={~p"/dashboard/vps"}
            class="inline-flex items-center justify-center h-10 px-4 py-2 rounded-md text-sm font-medium border border-primary/40 bg-background hover:border-primary hover:bg-primary/10 transition-all">
            Annuleren
          </.link>
        </div>
      </form>
    </div>
    """
  end
end
