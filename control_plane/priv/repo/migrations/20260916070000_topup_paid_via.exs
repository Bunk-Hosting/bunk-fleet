defmodule ControlPlane.Repo.Migrations.TopupPaidVia do
  use Ecto.Migration

  # Hoe een opwaardering op betaald is gekomen: `"mollie"` als de webhook van de
  # betaalprovider hem bevestigde, `"manual"` als een mens dat deed.
  #
  # Het verschil bepaalt of het bedrag omzet is. Een betaling die Mollie heeft
  # afgehandeld is geld dat binnenkwam; een die met de hand op betaald is gezet
  # kan van alles zijn. Tot nu toe was dat onderscheid nergens vastgelegd en
  # telde alles even hard mee in de btw-aangifte.
  #
  # Nullable, en die NULL betekent hier "van vóór deze kolom" — niet "handmatig".
  # De twee bestaande betaalde rijen komen allebei uit de Mollie-flow (hun
  # referentie ís het Mollie-betaal-id), maar of de webhook of een mens ze
  # bevestigde is niet meer te achterhalen. Die met terugwerkende kracht op
  # "mollie" zetten zou een aanname als feit vastleggen; de omzetberekening
  # behandelt NULL daarom als "tel mee", precies zoals het vandaag al werkte, en
  # sluit alleen uit wat expliciet als handmatig is geregistreerd.
  def change do
    alter table(:topup_requests) do
      add :paid_via, :string
    end

    create index(:topup_requests, [:paid_via])
  end
end
