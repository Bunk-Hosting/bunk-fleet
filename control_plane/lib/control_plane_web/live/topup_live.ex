defmodule ControlPlaneWeb.TopupLive do
  @moduledoc "Portal: self-service wallet top-up via bank/iDEAL with a payment reference."
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Credits

  @presets [1000, 2500, 5000, 10000]

  def mount(_params, _session, socket), do: {:ok, assign_state(socket, nil)}

  defp assign_state(socket, error) do
    uid = socket.assigns.current_user.id

    payment =
      Map.merge(
        %{iban: "—", beneficiary: "Bunk Hosting", bic: "—"},
        Map.new(Application.get_env(:control_plane, :payment, []))
      )

    assign(socket,
      balance_cents: Credits.balance_cents(uid),
      requests: Credits.list_topup_requests(uid, 10),
      presets: @presets,
      payment: payment,
      error: error
    )
  end

  def handle_event("request", %{"amount_eur" => amount}, socket) do
    case parse_amount(amount) do
      {:ok, cents} ->
        case Credits.create_topup_request(socket.assigns.current_user.id, cents) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_state(nil)
             |> put_flash(:info, "Aanvraag aangemaakt. Maak het bedrag over met de vermelde referentie; je tegoed verschijnt na bevestiging.")}

          {:error, _} ->
            {:noreply, assign_state(socket, "Bedrag moet tussen €5,00 en €1000,00 liggen.")}
        end

      :error ->
        {:noreply, assign_state(socket, "Voer een geldig bedrag in.")}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Credits.cancel_topup_request(socket.assigns.current_user.id, id)
    {:noreply, assign_state(socket, nil)}
  end

  defp parse_amount(s) do
    # Upper bound guards against a giant float overflowing round/2; the changeset
    # still enforces the real €5–€1000 business limits.
    case Float.parse(String.replace(String.trim(to_string(s)), ",", ".")) do
      {eur, _} when eur > 0 and eur <= 100_000 -> {:ok, round(eur * 100)}
      _ -> :error
    end
  end

  defp eur(cents), do: "€" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp status_label(:pending), do: "wacht op betaling"
  defp status_label(:paid), do: "bijgeboekt"
  defp status_label(:cancelled), do: "geannuleerd"

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <div class="hdr">
        <div>
          <h1>Tegoed aanvullen</h1>
          <p class="muted">Huidig saldo: <strong>{eur(@balance_cents)}</strong></p>
        </div>
        <.link navigate={~p"/app"} class="badge">← Mijn servers</.link>
      </div>

      <p :if={@flash["info"]} class="flash-info">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={@error} class="flash-err">{@error}</p>

      <h2>1. Kies een bedrag</h2>
      <div class="presets">
        <button :for={p <- @presets} phx-click="request" phx-value-amount_eur={Integer.to_string(div(p, 100))}>
          {eur(p)}
        </button>
      </div>
      <form phx-submit="request" class="custom">
        <input type="text" name="amount_eur" inputmode="decimal" placeholder="ander bedrag, bv. 15" />
        <button type="submit">Aanvragen</button>
      </form>

      <h2>2. Betaalgegevens</h2>
      <p class="muted">Maak het bedrag over en zet de <strong>referentie</strong> van je aanvraag in de omschrijving. Na ontvangst boeken we je tegoed bij.</p>
      <table class="pay">
        <tbody>
          <tr><td>Begunstigde</td><td>{@payment.beneficiary}</td></tr>
          <tr><td>IBAN</td><td><code>{@payment.iban}</code></td></tr>
          <tr><td>BIC</td><td><code>{@payment.bic}</code></td></tr>
        </tbody>
      </table>

      <h2>Je aanvragen</h2>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Datum</th><th>Bedrag</th><th>Referentie</th><th>Status</th><th></th></tr></thead>
          <tbody>
            <tr :for={r <- @requests}>
              <td class="muted">{Calendar.strftime(r.inserted_at, "%d-%m %H:%M")}</td>
              <td>{eur(r.amount_cents)}</td>
              <td><code>{r.reference}</code></td>
              <td class="muted">{status_label(r.status)}</td>
              <td>
                <button :if={r.status == :pending} class="ghost" phx-click="cancel" phx-value-id={r.id}
                        data-confirm="Aanvraag annuleren?">annuleren</button>
              </td>
            </tr>
            <tr :if={@requests == []}><td class="muted" colspan="5">Nog geen aanvragen.</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <style>
      .wrap { max-width: 760px; margin: 0 auto; padding: 28px 20px; }
      .hdr { display:flex; justify-content:space-between; align-items:flex-start; }
      .badge { font-size:12px; color:#8b949e; text-decoration:none; border:1px solid #2d3540; padding:5px 10px; border-radius:7px; }
      h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:15px; margin-top:24px; }
      .muted { color:#8b949e; font-size:13px; line-height:1.7; }
      .presets { display:flex; gap:10px; flex-wrap:wrap; margin:8px 0; }
      .presets button { padding:10px 18px; background:#161b22; border:1px solid #2d3540; border-radius:8px; color:#e6edf3; font-weight:600; cursor:pointer; }
      .presets button:hover { border-color:#3081f7; }
      .custom { display:flex; gap:10px; margin-top:6px; }
      .custom input { padding:9px 12px; background:#0b0f14; border:1px solid #2d3540; border-radius:8px; color:#e6edf3; }
      .custom button, .table-wrap button { cursor:pointer; }
      .custom button { padding:9px 18px; background:#2563eb; border:none; border-radius:8px; color:#fff; font-weight:600; }
      table { width:100%; border-collapse:collapse; margin-top:8px; font-size:13px; }
      th, td { text-align:left; padding:7px 8px; border-bottom:1px solid #1c2330; }
      table.pay td:first-child { color:#8b949e; width:140px; }
      code { background:#0b0f14; border:1px solid #2d3540; border-radius:6px; padding:2px 7px; }
      button.ghost { background:#21262d; border:1px solid #2d3540; border-radius:7px; color:#e6edf3; font-size:12px; padding:4px 10px; }
      .flash-info { background:#0f2417; border:1px solid #1c5236; color:#7ee2a8; padding:9px 12px; border-radius:8px; font-size:13px; }
      .flash-err { background:#2d1417; border:1px solid #5c2228; color:#ff9b9b; padding:9px 12px; border-radius:8px; font-size:13px; }
    </style>
    """
  end
end
