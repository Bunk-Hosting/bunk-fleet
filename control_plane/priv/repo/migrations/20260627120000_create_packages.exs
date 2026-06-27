defmodule ControlPlane.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  def change do
    create table(:packages) do
      add :name, :string, null: false
      add :cpu_cores, :integer, null: false
      add :ram_gb, :integer, null: false
      add :disk_gb, :integer, null: false
      add :bandwidth_tb, :integer, null: false, default: 1
      add :price_monthly, :decimal, precision: 8, scale: 2, null: false
      add :description, :string
      add :is_available, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      add :template_id, :integer, null: false, default: 9000
      timestamps(type: :utc_datetime)
    end

    create unique_index(:packages, [:name])

    alter table(:vpses) do
      add :package_id, references(:packages, on_delete: :nilify_all)
    end

    execute(
      """
      INSERT INTO packages (name,cpu_cores,ram_gb,disk_gb,bandwidth_tb,price_monthly,description,is_available,sort_order,template_id,inserted_at,updated_at) VALUES
      ('Starter',1,1,20,1,3.99,'Ideaal voor kleine projecten en experimenteren.',true,1,9000,NOW(),NOW()),
      ('Basic',2,2,40,2,7.99,'Voor websites en kleine applicaties.',true,2,9000,NOW(),NOW()),
      ('Pro',4,8,80,5,14.99,'Voor productieomgevingen en zwaardere workloads.',true,3,9000,NOW(),NOW()),
      ('Business',8,16,160,10,29.99,'Voor enterprise-applicaties en hoog verkeer.',true,4,9000,NOW(),NOW())
      """,
      "DELETE FROM packages"
    )
  end
end
