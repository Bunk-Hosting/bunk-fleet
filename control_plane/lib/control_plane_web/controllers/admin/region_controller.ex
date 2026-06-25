defmodule ControlPlaneWeb.Admin.RegionController do
  @moduledoc """
  Operator/admin API for fleet regions.

  Protected by `ControlPlaneWeb.Plugs.AdminAuth` (shared-secret admin token).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Region

  def index(conn, _params) do
    regions = Enum.map(Fleet.list_regions(), &region_json/1)
    json(conn, %{regions: regions})
  end

  def create(conn, params) do
    attrs = %{
      code: params["code"],
      name: params["name"],
      enabled: params["enabled"]
    }

    case Fleet.create_region(attrs) do
      {:ok, region} ->
        conn
        |> put_status(:created)
        |> json(%{region: region_json(region)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_region", details: errors(changeset)})
    end
  end

  defp region_json(%Region{} = region) do
    %{
      id: region.id,
      code: region.code,
      name: region.name,
      enabled: region.enabled
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
