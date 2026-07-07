defmodule ControlPlane.Repo.Migrations.AddSubscriptionRetryAt do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      # Throttles past_due retries WITHOUT touching next_billing_date, which stays
      # the customer's original billing anchor. Previously the retry overwrote the
      # anchor, so every insufficient-credit blip drifted the billing day forward,
      # granting free days.
      add :retry_at, :date
    end
  end
end
