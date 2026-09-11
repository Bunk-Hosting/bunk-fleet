defmodule ControlPlane.Credits.TopupRequest do
  @moduledoc """
  A customer-initiated request to top up their prepaid wallet. Until a real
  payment provider (Mollie) is wired, the flow is: customer creates a request and
  receives a unique payment `reference`, pays by bank/iDEAL quoting it, and an
  admin confirms receipt (which credits the wallet). This keeps the customer's
  data minimal (amount + reference only) per data-minimisation (AVG/GDPR).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "topup_requests" do
    field :amount_cents, :integer
    field :reference, :string
    field :status, Ecto.Enum, values: [:pending, :paid, :cancelled], default: :pending
    field :paid_at, :utc_datetime
    field :mollie_payment_id, :string
    belongs_to :user, ControlPlane.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(req, attrs) do
    req
    |> cast(attrs, [:user_id, :amount_cents, :reference, :status, :paid_at, :mollie_payment_id])
    |> validate_required([:user_id, :amount_cents, :reference, :status])
    |> validate_number(:amount_cents,
      greater_than_or_equal_to: 500,
      less_than_or_equal_to: 100_000
    )
    |> unique_constraint(:reference)
  end
end
