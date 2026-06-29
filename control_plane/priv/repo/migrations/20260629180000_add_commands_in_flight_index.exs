defmodule ControlPlane.Repo.Migrations.AddCommandsInFlightIndex do
  use Ecto.Migration

  def change do
    # Serves the 30s metering teardown subquery (kind in [...] and status in
    # [:pending,:delivered]) + power/delete-in-flight checks, which the
    # (node_id,status) and (vps_id) indexes don't cover. Partial -> tiny.
    create index(:commands, [:vps_id, :kind],
             where: "status IN ('pending', 'delivered')",
             name: :commands_in_flight_idx
           )
  end
end
