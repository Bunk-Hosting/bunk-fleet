defmodule ControlPlane.Fleet.Package do
  @moduledoc "A VPS plan with fixed specs + monthly price (replica of vps-backend VpsPackage)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "packages" do
    field :name, :string
    field :cpu_cores, :integer
    field :ram_gb, :integer
    field :disk_gb, :integer
    # De snelheid van de netwerkkaart van de gast, in megabit per seconde. Dit is
    # een bovengrens die de hypervisor afdwingt en geen gegarandeerde doorvoer:
    # de uplink is gedeeld. Daarom "tot" in de teksten.
    field :bandwidth_mbit, :integer, default: 200
    field :price_monthly, :decimal
    field :description, :string
    field :is_available, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :template_id, :integer, default: 9000

    timestamps(type: :utc_datetime)
  end

  def changeset(package, attrs) do
    package
    |> cast(attrs, [
      :name,
      :cpu_cores,
      :ram_gb,
      :disk_gb,
      :bandwidth_mbit,
      :price_monthly,
      :description,
      :is_available,
      :sort_order,
      :template_id
    ])
    |> validate_required([:name, :cpu_cores, :ram_gb, :disk_gb, :price_monthly])
    |> unique_constraint(:name)
  end
end
