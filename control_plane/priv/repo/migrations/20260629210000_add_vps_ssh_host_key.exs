defmodule ControlPlane.Repo.Migrations.AddVpsSshHostKey do
  use Ecto.Migration

  # Stores the trust-on-first-use SSH host-key fingerprint of each VPS, recorded on
  # its first browser-console connection and enforced on every later one (O-33).
  def change do
    alter table(:vpses) do
      add :ssh_host_key, :string
    end
  end
end
