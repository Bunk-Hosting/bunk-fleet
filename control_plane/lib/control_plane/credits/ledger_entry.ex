defmodule ControlPlane.Credits.LedgerEntry do
  @moduledoc "A single signed-cents movement in a customer's prepaid credit wallet."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ledger_entries" do
    field :amount_cents, :integer
    field :kind, :string
    field :description, :string
    belongs_to :user, ControlPlane.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :amount_cents, :kind, :description])
    |> validate_required([:user_id, :amount_cents, :kind])
  end
end
