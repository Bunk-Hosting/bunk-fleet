defmodule ControlPlane.Subscriptions.Subscription do
  @moduledoc "A recurring charge for a VPS's package (replica of vps-backend Subscription)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "subscriptions" do
    field :price_monthly, :decimal
    # :past_due — a recurring charge failed for lack of credit; the VPS is
    # suspended and the runner retries daily until it clears (back to :active).
    field :status, Ecto.Enum, values: [:active, :cancelled, :past_due], default: :active
    field :billing_cycle, Ecto.Enum, values: [:monthly, :yearly], default: :monthly
    field :started_at, :utc_datetime
    # The billing ANCHOR: the date the current period runs to. Never mutated by a
    # failed charge — past_due retries are throttled via :retry_at instead, so the
    # customer's billing day doesn't drift forward (free days) on payment blips.
    field :next_billing_date, :date
    # When a past_due subscription may next be retried (nil = no throttle).
    field :retry_at, :date
    field :cancelled_at, :utc_datetime
    field :package_id, :integer

    belongs_to :vps, ControlPlane.Fleet.Vps
    belongs_to :owner, ControlPlane.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [
      :vps_id,
      :owner_id,
      :package_id,
      :price_monthly,
      :status,
      :billing_cycle,
      :started_at,
      :next_billing_date,
      :cancelled_at
    ])
    |> validate_required([:vps_id, :owner_id, :price_monthly])
    |> unique_constraint(:vps_id)
  end
end
