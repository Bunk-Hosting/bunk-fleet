defmodule ControlPlane.Overlay.Config do
  @moduledoc "Singleton (id=1) holding the WireGuard hub keypair for the overlay."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "overlay_config" do
    field :hub_private_key, :string, redact: true
    field :hub_public_key, :string

    timestamps(type: :utc_datetime)
  end
end
