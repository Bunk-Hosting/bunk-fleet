defmodule ControlPlane.Idempotency.Key do
  @moduledoc "Eén geclaimde idempotentiesleutel; zie `ControlPlane.Idempotency`."
  use Ecto.Schema

  import Ecto.Changeset

  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Vps

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "idempotency_keys" do
    field :key, :string
    field :scope, :string
    field :status, :string, default: "in_flight"

    belongs_to :user, User
    belongs_to :vps, Vps

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(rij, attrs) do
    rij
    |> cast(attrs, [:user_id, :key, :scope, :status, :vps_id])
    |> validate_required([:user_id, :key, :scope, :status])
    |> unique_constraint([:user_id, :scope, :key])
  end
end
