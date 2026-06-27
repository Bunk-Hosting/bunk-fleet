defmodule ControlPlane.Subscriptions.Subscription do
  @moduledoc "A recurring charge for a VPS's package (replica of vps-backend Subscription)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "subscriptions" do
    field :price_monthly, :decimal
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :billing_cycle, Ecto.Enum, values: [:monthly, :yearly], default: :monthly
    field :started_at, :utc_datetime
    field :next_billing_date, :date
    field :cancelled_at, :utc_datetime
    field :package_id, :integer

    belongs_to :vps, ControlPlane.Fleet.Vps
    belongs_to :owner, ControlPlane.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:vps_id, :owner_id, :package_id, :price_monthly, :status, :billing_cycle, :started_at, :next_billing_date, :cancelled_at])
    |> validate_required([:vps_id, :owner_id, :price_monthly])
    |> unique_constraint(:vps_id)
  end
end
