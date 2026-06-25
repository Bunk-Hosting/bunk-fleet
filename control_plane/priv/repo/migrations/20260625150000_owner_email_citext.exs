defmodule ControlPlane.Repo.Migrations.OwnerEmailCitext do
  use Ecto.Migration

  # The payout/scoping key `owner_email` is compared against `users.email`, which
  # is `citext` (case-insensitive). Make the three denormalized snapshots `citext`
  # too so "list my nodes / my earnings" matching can't silently split across
  # casings — instead of relying on every write path downcasing forever.
  #
  # The `citext` extension is already created (see CreateUsers). text → citext is
  # value-preserving, so the USING cast is a no-op on existing (lowercased) data.
  @columns [
    {"enroll_tokens", "owner_email"},
    {"nodes", "owner_email"},
    {"usage_records", "owner_email"}
  ]

  def up do
    for {table, col} <- @columns do
      execute("ALTER TABLE #{table} ALTER COLUMN #{col} TYPE citext USING #{col}::citext")
    end
  end

  def down do
    for {table, col} <- @columns do
      execute("ALTER TABLE #{table} ALTER COLUMN #{col} TYPE text USING #{col}::text")
    end
  end
end
