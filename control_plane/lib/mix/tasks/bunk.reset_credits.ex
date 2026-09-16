defmodule Mix.Tasks.Bunk.ResetCredits do
  @shortdoc "Zet alle tegoeden terug op nul met een zichtbare correctieregel"

  @moduledoc """
  Zet het tegoed van iedere gebruiker terug op nul.

  Wat er tot nu toe op de saldi stond kwam uit de testperiode: handmatige
  ophogingen uit het beheerpaneel van duizenden euro's, en opwaarderingen die
  met de testsleutel van Mollie op betaald zijn gezet. Daar heeft nooit geld in
  gezeten, en zolang het bleef staan kon ermee besteld worden.

  Er wordt niets weggehaald. Het grootboek is de verantwoording en hoort alleen
  aan te groeien; een saldo dat verandert doordat oude regels verdwijnen is niet
  meer na te rekenen. In plaats daarvan komt er per gebruiker één regel bij die
  het saldo precies op nul brengt, met in de omschrijving waarom.

      mix bunk.reset_credits          # laat zien wat er zou gebeuren
      mix bunk.reset_credits --doen   # en voer het uit
  """

  use Mix.Task

  import Ecto.Query

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Repo

  @kind "correction"
  @description "Saldo teruggezet bij de overgang naar echte betalingen"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [doen: :boolean])

    Mix.Task.run("app.start")

    saldi_ongelijk_aan_nul()
    |> toon()
    |> voer_uit(Keyword.get(opts, :doen, false))
  end

  defp toon([]) do
    Mix.shell().info("Alle tegoeden staan al op nul.")
    []
  end

  defp toon(saldi) do
    Enum.each(saldi, fn %{email: email, saldo: saldo} ->
      Mix.shell().info("#{pad(email)} #{euro(saldo)} -> #{euro(0)}")
    end)

    saldi
  end

  defp voer_uit([], _doen?), do: :ok

  defp voer_uit(saldi, false) do
    Mix.shell().info("\nDit is een proefdraai over #{length(saldi)} tegoed(en). Voeg --doen toe.")
  end

  defp voer_uit(saldi, true) do
    Enum.each(saldi, fn %{user_id: user_id, saldo: saldo} ->
      {:ok, _} = Credits.add_entry(user_id, -saldo, @kind, @description)
    end)

    Mix.shell().info("\n#{length(saldi)} tegoed(en) teruggezet.")
  end

  # Het saldo is de som van het grootboek en geen kolom die wordt bijgehouden;
  # daarom wordt het hier ook zo uitgerekend in plaats van uit users gelezen.
  defp saldi_ongelijk_aan_nul do
    from(l in LedgerEntry,
      join: u in assoc(l, :user),
      group_by: [l.user_id, u.email],
      having: sum(l.amount_cents) != 0,
      order_by: [desc: sum(l.amount_cents)],
      select: %{user_id: l.user_id, email: u.email, saldo: sum(l.amount_cents)}
    )
    |> Repo.all()
  end

  defp euro(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2) <> " EUR"

  defp pad(text), do: String.pad_trailing(text, 34)
end
