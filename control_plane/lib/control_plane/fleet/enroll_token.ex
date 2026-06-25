defmodule ControlPlane.Fleet.EnrollToken do
  @moduledoc """
  A single-use, time-limited token handed to a worker node operator so a
  `bunk-agent` can enroll a new `ControlPlane.Fleet.Node` into a given region/tier.

  Only the SHA-256 hash of the token is persisted (`token_hash`); the plaintext is
  shown to the operator exactly once at creation time. A token is valid while it is
  unexpired (`expires_at` in the future) and unused (`used_at` is nil).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Region

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enroll_tokens" do
    field :token_hash, :string
    field :tier, Ecto.Enum, values: [:datacenter, :community], default: :community
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :region, Region

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(enroll_token, attrs) do
    enroll_token
    |> cast(attrs, [:token_hash, :tier, :expires_at, :used_at, :region_id])
    |> validate_required([:token_hash, :region_id])
    |> unique_constraint(:token_hash)
    |> assoc_constraint(:region)
  end
end
