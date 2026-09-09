defmodule ControlPlane.Repo.Migrations.DropNodeTrustTier do
  use Ecto.Migration

  # The :datacenter/:community tier was a TRUST boundary: it kept a "secure" VPS
  # off bring-your-own hardware whose external operator had full disk/RAM/console
  # access (misuse case O-24). Bunk now runs only its own nodes, so there is no
  # untrusted class of hardware left and the distinction has no meaning.
  #
  # Leaving it half-used was actively harmful: metering skipped :datacenter nodes,
  # so once every node became ours the usage accounting silently recorded nothing.
  def up do
    alter table(:nodes), do: remove(:tier)
    alter table(:vpses), do: remove(:tier)
    alter table(:enroll_tokens), do: remove(:tier)
  end

  def down do
    alter table(:nodes), do: add(:tier, :string, null: false, default: "community")
    alter table(:vpses), do: add(:tier, :string, null: false, default: "community")
    alter table(:enroll_tokens), do: add(:tier, :string, null: false, default: "community")
  end
end
