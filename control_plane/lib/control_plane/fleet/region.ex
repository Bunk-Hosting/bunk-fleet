defmodule ControlPlane.Fleet.Region do
  @moduledoc """
  A geographic/logical region into which fleet nodes are grouped (e.g. "nl-1").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "regions" do
    field :code, :string
    field :name, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(region, attrs) do
    region
    |> cast(attrs, [:code, :name, :enabled])
    |> validate_required([:code, :name])
    |> unique_constraint(:code)
  end
end
