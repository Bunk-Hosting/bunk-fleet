defmodule ControlPlane.Repo.Migrations.NodeOwner do
  use Ecto.Migration

  # Een node had alleen `owner_email`, een los tekstveld dat als kostenplaats
  # dient. Het enroll-token heeft wél een echte koppeling naar een gebruiker,
  # maar die werd bij het inschrijven niet overgenomen -- er was dus nergens vast
  # te stellen wie een node beheert.
  #
  # Dat is nu nodig: de eigenaar mag de instellingen van zijn node wijzigen en
  # een ander niet. ON DELETE SET NULL, want een node hoort niet mee te verdwijnen
  # met het account van zijn eigenaar; hij wordt dan eigenaarloos en een beheerder
  # wijst hem opnieuw toe.
  def change do
    alter table(:nodes) do
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:nodes, [:owner_id])
  end
end
