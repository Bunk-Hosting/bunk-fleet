defmodule ControlPlane.Accounts.Passkey do
  @moduledoc """
  Een geregistreerde passkey (WebAuthn-credential) van een gebruiker.

  De publieke sleutel is de COSE-structuur die wax oplevert, opgeslagen als
  Erlang-term. Hij wordt alleen door wax weer gelezen, en `binary_to_term` met
  `:safe` weigert alles wat geen bestaand atoom of platte data is.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_passkeys" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :label, :string
    field :last_used_at, :utc_datetime
    belongs_to :user, ControlPlane.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @max_label 60

  def changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :label, :last_used_at])
    |> validate_required([:user_id, :credential_id, :public_key, :label])
    |> validate_length(:label, min: 1, max: @max_label)
    # Het label komt uit de browser en belandt in het dashboard: geen
    # controltekens, net als bij een VPS-naam.
    |> validate_format(:label, ~r/\A[^\x00-\x1F\x7F]*\z/,
      message: "mag geen controltekens bevatten"
    )
    |> unique_constraint(:credential_id)
  end

  @doc "De COSE-sleutel als term, voor wax."
  def cose_key(%__MODULE__{public_key: bin}), do: :erlang.binary_to_term(bin, [:safe])

  @doc "Een COSE-sleutel van wax als opslagbare binary."
  def encode_cose_key(key), do: :erlang.term_to_binary(key)
end
