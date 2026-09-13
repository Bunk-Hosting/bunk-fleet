defmodule ControlPlane.Repo.Migrations.LedgerEntryVps do
  use Ecto.Migration

  # Which machine a charge paid for. Nullable, and the null is the point: a
  # `vps_charge` without one is a charge whose VPS never came into existence,
  # which until now could only be found by a person matching timestamps by hand.
  #
  # nilify_all rather than delete_all: a customer's financial history must
  # survive the machine it was about. Deleting a VPS is not a reason to forget
  # that they paid for it.
  def change do
    alter table(:ledger_entries) do
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :nilify_all)
    end

    # The sweep asks "which vps_charge rows have no VPS and are older than the
    # grace period"; without this it reads the whole ledger to answer.
    create index(:ledger_entries, [:kind, :vps_id])
  end
end
