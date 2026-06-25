defmodule ControlPlaneWeb.VpsController do
  @moduledoc """
  End-user VPS API: a registered user manages only the VPSes they own.

  Authenticated by `ControlPlaneWeb.Plugs.ApiAuth`, so `conn.assigns.current_user`
  is always present. Ownership is enforced on every read and on delete by scoping
  queries to `current_user.id`; a VPS belonging to someone else is indistinguishable
  from one that does not exist (404), never leaking its existence.

  `create` provisions on behalf of the current user (stamping `owner_id` and
  `owner_email` server-side — never from the request body) and accepts either a
  `region_id` or a human `region_code`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.{Region, Vps}
  alias ControlPlane.Provisioning

  def index(conn, _params) do
    vpses =
      conn.assigns.current_user.id
      |> Fleet.list_vpses_for_owner()
      |> Enum.map(&vps_json/1)

    json(conn, %{vpses: vpses})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id) do
      json(conn, %{vps: vps_json(vps)})
    else
      _ -> not_found(conn)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, region_id} <- resolve_region_id(params),
         {:ok, %{vps: vps}} <- Provisioning.create_vps(build_attrs(params, region_id, user)) do
      conn
      |> put_status(:created)
      |> json(%{vps: vps_json(vps)})
    else
      {:error, :region_not_found} -> error(conn, :unprocessable_entity, "region_not_found")
      {:error, :no_capacity} -> error(conn, :conflict, "no_capacity")
      {:error, _reason} -> error(conn, :unprocessable_entity, "invalid_vps")
    end
  end

  def delete(conn, %{"id" => id}) do
    # Authorize first: only an owned VPS may be deleted. An unknown id, a bad id, or
    # someone else's VPS all collapse to 404 so ownership isn't leaked.
    with {:ok, id} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id),
         {:ok, %{vps: vps}} <- Provisioning.delete_vps(id) do
      conn
      |> put_status(:accepted)
      |> json(%{vps: vps_json(vps)})
    else
      {:error, :already_deleting} -> error(conn, :conflict, "already_deleting")
      {:error, :no_node} -> error(conn, :unprocessable_entity, "no_node")
      _ -> not_found(conn)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp build_attrs(params, region_id, user) do
    %{
      region_id: region_id,
      name: params["name"],
      vcpu: params["vcpu"],
      ram_mb: params["ram_mb"],
      disk_gb: params["disk_gb"],
      # Ownership is taken from the authenticated session, never the request body.
      owner_id: user.id,
      owner_email: user.email,
      template_id: default_template_id(),
      ssh_keys: params["ssh_keys"] || [],
      cloud_init: params["cloud_init"] || %{},
      ip_config: params["ip_config"]
    }
  end

  defp resolve_region_id(%{"region_id" => region_id}) when is_binary(region_id) do
    case valid_id(region_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :region_not_found}
    end
  end

  defp resolve_region_id(%{"region_code" => region_code}) when is_binary(region_code) do
    case Fleet.region_by_code(region_code) do
      %Region{id: id} -> {:ok, id}
      nil -> {:error, :region_not_found}
    end
  end

  defp resolve_region_id(_params), do: {:error, :region_not_found}

  defp valid_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp valid_id(_), do: :error

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  defp vps_json(%Vps{} = vps) do
    %{
      id: vps.id,
      name: vps.name,
      status: vps.status,
      region: region_code(vps),
      provider_vm_id: vps.provider_vm_id,
      ip_address: vps.ip_address,
      vcpu: vps.vcpu,
      ram_mb: vps.ram_mb,
      disk_gb: vps.disk_gb,
      inserted_at: vps.inserted_at
    }
  end

  defp region_code(%Vps{region: %{code: code}}), do: code
  defp region_code(%Vps{}), do: nil

  defp not_found(conn), do: error(conn, :not_found, "not_found")

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
