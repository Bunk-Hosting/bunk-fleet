defmodule ControlPlane.Repo.Migrations.IndexSubscriptionsNextBilling do
  use Ecto.Migration

  def change do
    # The recurring-billing runner scans for subscriptions whose next_billing_date
    # has arrived; index that column so the due-scan stays cheap as the table grows.
    create index(:subscriptions, [:next_billing_date])
  end
end
