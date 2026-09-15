defmodule ControlPlane.Repo.Migrations.UserPasskeys do
  use Ecto.Migration

  # Eén rij per geregistreerde passkey. Een gebruiker kan er meerdere hebben —
  # telefoon, laptop, een hardwaresleutel — en verliest er weleens een, dus ze
  # zijn los te verwijderen.
  #
  # credential_id is wat de authenticator terugstuurt en is wereldwijd uniek;
  # de uniqueness-index is de eis uit de WebAuthn-specificatie dat geen twee
  # accounts dezelfde credential mogen delen. public_key is de COSE-sleutel
  # zoals wax hem oplevert, opgeslagen als Erlang-term; hij hoeft nergens anders
  # leesbaar te zijn. sign_count is de teller van de authenticator: loopt hij
  # terug, dan is de sleutel mogelijk gekloond.
  def change do
    create table(:user_passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :label, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])
  end
end
