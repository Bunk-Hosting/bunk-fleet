defmodule ControlPlane.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      add :tier, :string, null: false, default: "community"
      add :status, :string, null: false, default: "pending"
      add :hypervisor, :string, null: false, default: "proxmox"

      add :total_vcpu, :integer
      add :total_ram_mb, :integer
      add :total_disk_gb, :integer

      add :available_vcpu, :integer
      add :available_ram_mb, :integer
      add :available_disk_gb, :integer

      add :last_heartbeat_at, :utc_datetime
      add :enroll_token_hash, :string
      add :public_key, :string
      add :owner_email, :string

      add :region_id, references(:regions, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:nodes, [:region_id])
    create index(:nodes, [:region_id, :status])

    # DB-level backstop against overcommit: available capacity can never go
    # negative, nor exceed the advertised total. If the scheduler ever tries to
    # decrement below zero, the transaction fails loudly instead of silently
    # persisting an overcommitted node.
    create constraint(:nodes, :available_nonneg,
             check: "available_vcpu >= 0 AND available_ram_mb >= 0 AND available_disk_gb >= 0"
           )

    create constraint(:nodes, :available_within_total,
             check:
               "(total_vcpu IS NULL OR available_vcpu IS NULL OR available_vcpu <= total_vcpu) AND " <>
                 "(total_ram_mb IS NULL OR available_ram_mb IS NULL OR available_ram_mb <= total_ram_mb) AND " <>
                 "(total_disk_gb IS NULL OR available_disk_gb IS NULL OR available_disk_gb <= total_disk_gb)"
           )
  end
end
