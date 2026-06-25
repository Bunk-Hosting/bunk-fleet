defmodule ControlPlane.Repo do
  use Ecto.Repo,
    otp_app: :control_plane,
    adapter: Ecto.Adapters.Postgres
end
