defmodule ControlPlane.Repo.Migrations.PartialIndexSubscriptionsDue do
  use Ecto.Migration

  def change do
    # The recurring-billing due-scan only ever looks at :active/:past_due
    # subscriptions ordered by next_billing_date. The old plain index on
    # next_billing_date also indexes every cancelled/finished subscription, so it
    # bloats and slows as churn accumulates. Replace it with a partial index that
    # covers only the rows the scan actually reads.
    drop_if_exists index(:subscriptions, [:next_billing_date])

    create index(:subscriptions, [:next_billing_date],
             where: "status IN ('active', 'past_due')",
             name: :subscriptions_due_idx
           )
  end
end
