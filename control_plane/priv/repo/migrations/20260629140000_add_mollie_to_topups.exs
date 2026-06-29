defmodule ControlPlane.Repo.Migrations.AddMollieToTopups do
  use Ecto.Migration

  def change do
    alter table(:topup_requests) do
      add :mollie_payment_id, :string
    end

    create unique_index(:topup_requests, [:mollie_payment_id])
  end
end
