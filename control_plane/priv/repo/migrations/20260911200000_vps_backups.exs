defmodule ControlPlane.Repo.Migrations.VpsBackups do
  @moduledoc """
  Backups of the thing customers actually care about: their disk.

  The control plane has been backed up since this morning. A customer would
  reasonably assume that meant *their* VPS, and it did not — if a node's storage
  died, the data on it was gone, and if they broke their own machine there was no
  way back.

  These are node-local `vzdump` archives. That covers the common case (a customer
  broke their own VPS) and not the rare one (the node died with it). Saying which
  is which honestly is part of the feature.
  """
  use Ecto.Migration

  def change do
    create table(:vps_backups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vps_id, references(:vpses, type: :binary_id, on_delete: :delete_all), null: false
      # Where the archive physically is. A backup outlives the node row only in
      # the sense that it is useless without it, so this is nilified rather than
      # cascaded: the row stays as evidence of what existed.
      add :node_id, references(:nodes, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      # The hypervisor's own handle on the archive — a Proxmox volid such as
      # "local:backup/vzdump-qemu-106-2026_09_11-20_15_00.vma.zst". Opaque here;
      # only the agent that made it knows how to read it.
      add :volid, :string
      add :size_bytes, :bigint
      add :error, :text

      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:vps_backups, [:vps_id])
    # "Which VPSes are due a backup" and "what should I prune" are both this
    # query, newest first.
    create index(:vps_backups, [:vps_id, :finished_at])
    create unique_index(:vps_backups, [:node_id, :volid], where: "volid IS NOT NULL")
  end
end
