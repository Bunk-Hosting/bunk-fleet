defmodule ControlPlane.Fleet.EnrollToken do
  @moduledoc """
  A single-use, time-limited token handed to a worker node operator so a
  `bunk-agent` can enroll a new `ControlPlane.Fleet.Node` into a given region.

  Only the SHA-256 hash of the token is persisted (`token_hash`); the plaintext is
  shown to the operator exactly once at creation time. A token is valid while it is
  unexpired (`expires_at` in the future) and unused (`used_at` is nil).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Region

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enroll_tokens" do
    field :token_hash, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    # The operator who minted this token. `owner_email` is denormalized so it can
    # be copied onto the enrolled node (the cost centre). Both nil for an
    # admin-minted token with no operator owner.
    field :owner_email, :string

    belongs_to :region, Region
    belongs_to :user, User, foreign_key: :owner_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(enroll_token, attrs) do
    enroll_token
    |> cast(attrs, [:token_hash, :expires_at, :used_at, :region_id, :owner_id, :owner_email])
    |> validate_required([:token_hash, :region_id])
    |> unique_constraint(:token_hash)
    |> assoc_constraint(:region)
    |> assoc_constraint(:user)
  end
end
