defmodule ControlPlane.Repo.Migrations.UserAnonymisedAt do
  use Ecto.Migration

  # Een account waar een administratie aan hangt wordt bij verwijderen
  # geanonimiseerd in plaats van weggegooid: de persoonsgegevens gaan eruit, de
  # facturen en het grootboek blijven staan omdat die zeven jaar bewaard moeten
  # blijven.
  #
  # De rij blijft daardoor bestaan, en in het beheerscherm zag dat eruit als een
  # account dat niet verwijderd was -- met een onbegrijpelijk adres erbij. Dit
  # veld maakt de toestand expliciet in plaats van af te leiden uit de vorm van
  # het e-mailadres, zodat het scherm hem als verwijderd kan tonen en standaard
  # kan verbergen.
  def up do
    alter table(:users) do
      add :anonymised_at, :utc_datetime
    end

    # De accounts die al geanonimiseerd zijn, herkenbaar aan het vervangende
    # adres. Zonder deze backfill blijven ze er als gewone accounts uitzien.
    execute """
    UPDATE users
       SET anonymised_at = updated_at
     WHERE email LIKE '%@verwijderd.invalid'
    """

    create index(:users, [:anonymised_at])
  end

  def down do
    drop index(:users, [:anonymised_at])

    alter table(:users) do
      remove :anonymised_at
    end
  end
end
