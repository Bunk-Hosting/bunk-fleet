defmodule ControlPlane.Console.Sessielog.Regel do
  @moduledoc "Eén terminalsessie: wie, welke VPS, van wanneer tot wanneer."
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "console_sessions" do
    field :door_beheerder, :boolean, default: false
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :reden_einde, :string

    belongs_to :user, ControlPlane.Accounts.User
    belongs_to :vps, ControlPlane.Fleet.Vps

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(regel, attrs) do
    regel
    |> cast(attrs, [:user_id, :vps_id, :door_beheerder, :started_at, :ended_at, :reden_einde])
    |> validate_required([:started_at])
  end
end
