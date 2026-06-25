defmodule ControlPlane.Repo.Migrations.AddOwnerToEnrollTokens do
  use Ecto.Migration

  # Binds an enroll token (and so the node that redeems it) to the operator who
  # minted it. `owner_email` is denormalized onto the token and copied onto the
  # enrolled `Node` at enroll time so operator payouts can accrue (metering keys
  # off `nodes.owner_email`) and survive the operator account being deleted.
  # `owner_id` keeps referential integrity for "list my tokens/nodes" queries.
  def change do
    alter table(:enroll_tokens) do
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :owner_email, :string
    end

    create index(:enroll_tokens, [:owner_id])
  end
end
