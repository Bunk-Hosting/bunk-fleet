defmodule ControlPlane.Repo.Migrations.UserTokenLastUsed do
  use Ecto.Migration

  # Een sessie liep tot nu toe zestig dagen vanaf het inloggen en verder niets.
  # Wie eenmaal binnen was bleef binnen, of er nu iets gebeurde of niet — en een
  # gestolen token bleef precies zo lang bruikbaar. Met een tijdstip van laatst
  # gebruik kan een sessie ook op stilte verlopen, wat de echte bescherming is:
  # de meeste gestolen tokens worden pas dagen later ingezet.
  def up do
    alter table(:user_tokens) do
      add :last_used_at, :utc_datetime
    end

    # Bestaande sessies krijgen hun aanmaakmoment mee in plaats van NULL. NULL
    # zou hier "nooit gebruikt" betekenen en dus iedereen die nu is ingelogd er
    # in één keer uit gooien, terwijl deze rijen juist wél in gebruik zijn.
    execute "UPDATE user_tokens SET last_used_at = inserted_at WHERE context = 'session'"

    create index(:user_tokens, [:last_used_at])
  end

  def down do
    drop index(:user_tokens, [:last_used_at])

    alter table(:user_tokens) do
      remove :last_used_at
    end
  end
end
