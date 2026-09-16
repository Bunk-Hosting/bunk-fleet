defmodule ControlPlane.Repo.Migrations.MarkPreLiveTopupsAsTest do
  use Ecto.Migration

  # Mollie stond tot 14 september 2026 op de testsleutel. De opwaarderingen die
  # daarvoor op "betaald" kwamen te staan zien er in de database uit als echte
  # betalingen — status, bedrag en een Mollie-id — maar er is nooit geld voor
  # binnengekomen. Zolang ze als omzet meetelden stond er btw in de aangifte over
  # geld dat niet bestaat.
  #
  # Ze worden niet verwijderd. De rijen horen bij het tegoed dat er toen op is
  # bijgeschreven, en een boekhouding waar regels uit verdwijnen is minder waard
  # dan een waar staat waarom een regel niet meetelt. `paid_via` krijgt dus een
  # eigen waarde, en het omzetoverzicht laat ze onder "niet meegeteld" zien.
  @cutover ~U[2026-09-14 00:00:00Z]

  def up do
    execute(fn ->
      repo().query!(
        """
        UPDATE topup_requests
           SET paid_via = 'mollie_test', updated_at = now() AT TIME ZONE 'utc'
         WHERE status = 'paid' AND paid_via IS NULL AND paid_at < $1
        """,
        [@cutover]
      )
    end)

    # Alles wat na de overgang betaald is en tóch geen bevestiger heeft, is een
    # gat dat we niet stil willen dichten: liever een zichtbare waarde die in het
    # overzicht bij "niet meegeteld" belandt dan een NULL die meelift.
    execute(fn ->
      repo().query!(
        """
        UPDATE topup_requests
           SET paid_via = 'unknown', updated_at = now() AT TIME ZONE 'utc'
         WHERE status = 'paid' AND paid_via IS NULL
        """,
        []
      )
    end)
  end

  def down do
    execute(fn ->
      repo().query!(
        "UPDATE topup_requests SET paid_via = NULL WHERE paid_via IN ('mollie_test', 'unknown')",
        []
      )
    end)
  end
end
