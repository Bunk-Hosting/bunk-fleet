defmodule ControlPlaneWeb.PackageController do
  @moduledoc """
  Read-only VPS package catalog for the customer frontend.

  Packages are bunk-fleet's own domain (`ControlPlane.Fleet.Package`); this just
  exposes the available ones. Public, read-only catalog (no per-user data) — rate-limited, no auth gate.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet

  def index(conn, _params) do
    results = Enum.map(Fleet.list_available_packages(), &package_json/1)
    json(conn, %{count: length(results), results: results})
  end

  defp package_json(package) do
    %{
      id: package.id,
      name: package.name,
      cpu_cores: package.cpu_cores,
      ram_gb: package.ram_gb,
      disk_gb: package.disk_gb,
      bandwidth_tb: package.bandwidth_tb,
      bandwidth_mbit: package.bandwidth_mbit,
      price_monthly: Decimal.to_string(package.price_monthly),
      description: package.description
    }
  end
end
