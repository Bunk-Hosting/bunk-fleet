defmodule ControlPlane.Repo.Migrations.AddVpsTier do
  use Ecto.Migration

  # The trust tier a VPS requires of its host node (O-24). Defaults to :community
  # so existing rows and the current all-community fleet are unaffected; a
  # :datacenter VPS may only be scheduled onto a :datacenter node, so a paid
  # "secure" VPS can never land on untrusted bring-your-own-hardware.
  def change do
    alter table(:vpses) do
      add :tier, :string, null: false, default: "community"
    end
  end
end
