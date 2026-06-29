defmodule ControlPlaneWeb.ConsoleController do
  @moduledoc """
  Owner-scoped console access:

    * POST /api/v1/vpses/:id/console-ticket — the authenticated owner of an active
      VPS mints a single-use ticket for one WebSocket console session.
    * GET  /ws/console/:id?ticket=... — redeems the ticket (verifying it matches
      this VPS) and upgrades to `ConsoleSocket`, which SSHes into the VPS.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.ApiResponse

  alias ControlPlane.{Console, Fleet}
  alias ControlPlane.Fleet.Vps

  def create_ticket(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Vps{status: :active, ip_address: ip} <- Fleet.get_vps_for_owner(user.id, uuid),
         true <- is_binary(ip) and ip != "" do
      json(conn, %{ticket: Console.Tickets.mint(uuid, user.id)})
    else
      :error -> error(conn, :not_found, "not_found")
      nil -> error(conn, :not_found, "not_found")
      %Vps{} -> error(conn, :conflict, "vps_not_active")
      false -> error(conn, :conflict, "console_unavailable")
    end
  end

  def ws(conn, %{"id" => id} = params) do
    with {:ok, %{vps_id: vps_id, user_id: user_id}} <- Console.Tickets.redeem(params["ticket"]),
         true <- vps_id == id,
         %Vps{status: :active, ip_address: ip} <- Fleet.get_vps_for_owner(user_id, vps_id),
         true <- is_binary(ip) and ip != "" do
      state = %{host: ip, port: 22, user: console_user(), user_id: user_id, vps_id: vps_id}

      conn
      |> WebSockAdapter.upgrade(ControlPlaneWeb.ConsoleSocket, state, timeout: 60_000)
      |> halt()
    else
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp console_user, do: (Application.get_env(:control_plane, :console) || [])[:ssh_user] || "ubuntu"
end
