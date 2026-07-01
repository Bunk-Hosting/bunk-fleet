defmodule ControlPlaneWeb.Admin.PanelController do
  @moduledoc """
  Session-authenticated admin panel API (`/api/v1/admin/*`), gated by
  `ControlPlaneWeb.Plugs.RequireAdmin` (role == :admin on the caller's own token).

  Powers the dashboard admin section: platform stats, user management (role +
  wallet adjustments), a fleet-wide VPS view with lifecycle actions, and a node
  overview. All actions are authorized purely by the admin role — they are NOT
  owner-scoped (that's the whole point of an admin panel).
  """
  use ControlPlaneWeb, :controller
  import Ecto.Query

  alias ControlPlane.{Accounts, Credits, Fleet, Provisioning, Repo}
  alias ControlPlane.Accounts.User
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.{Node, Vps}

  # --- Stats ---------------------------------------------------------------

  def stats(conn, _params) do
    by_role = count_by(from(u in User), :role)
    by_status = count_by(from(v in Vps), :status)
    nodes = Repo.all(from n in Node, select: {n.status, n.tier})

    outstanding =
      Repo.one(from e in LedgerEntry, select: coalesce(sum(e.amount_cents), 0)) || 0

    json(conn, %{
      users: %{
        total: map_total(by_role),
        user: Map.get(by_role, :user, 0),
        operator: Map.get(by_role, :operator, 0),
        admin: Map.get(by_role, :admin, 0)
      },
      vpses: %{
        total: map_total(Map.delete(by_status, :deleted)),
        active: Map.get(by_status, :active, 0),
        stopped: Map.get(by_status, :stopped, 0),
        provisioning: Map.get(by_status, :provisioning, 0) + Map.get(by_status, :queued, 0),
        failed: Map.get(by_status, :failed, 0)
      },
      nodes: %{
        total: length(nodes),
        online: Enum.count(nodes, fn {s, _} -> s == :online end),
        datacenter: Enum.count(nodes, fn {_, t} -> t == :datacenter end),
        community: Enum.count(nodes, fn {_, t} -> t == :community end)
      },
      credit_outstanding_cents: outstanding
    })
  end

  # --- Users ---------------------------------------------------------------

  def users(conn, _params) do
    users = Repo.all(from u in User, order_by: [asc: u.inserted_at])

    vps_counts =
      Repo.all(
        from v in Vps,
          where: v.status not in [:deleted, :failed],
          group_by: v.owner_id,
          select: {v.owner_id, count(v.id)}
      )
      |> Map.new()

    balances =
      Repo.all(from e in LedgerEntry, group_by: e.user_id, select: {e.user_id, sum(e.amount_cents)})
      |> Map.new()

    json(conn, %{
      users:
        Enum.map(users, fn u ->
          %{
            id: u.id,
            name: u.name,
            email: u.email,
            role: u.role,
            confirmed: not is_nil(u.confirmed_at),
            two_factor: not is_nil(u.totp_confirmed_at),
            inserted_at: DateTime.to_iso8601(u.inserted_at),
            vps_count: Map.get(vps_counts, u.id, 0),
            balance_cents: to_int(Map.get(balances, u.id, 0))
          }
        end)
    })
  end

  def update_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, role} <- parse_role(params) do
      cond do
        # Never let an admin strip their OWN admin role (self-lockout guard).
        user.id == conn.assigns.current_user.id and role != :admin ->
          error(conn, :unprocessable_entity, "cannot_demote_self")

        true ->
          case Accounts.update_user_role(user, role) do
            {:ok, u} -> json(conn, %{id: u.id, role: u.role})
            {:error, _} -> error(conn, :unprocessable_entity, "update_failed")
          end
      end
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  def credit_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, cents} <- parse_amount(params) do
      {:ok, _} =
        Credits.add_entry(user.id, cents, "admin_adjustment", "Handmatige aanpassing door beheerder")

      json(conn, %{id: user.id, balance_cents: Credits.balance_cents(user.id)})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_amount} -> error(conn, :unprocessable_entity, "invalid_amount")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  # --- VPSes ---------------------------------------------------------------

  def vpses(conn, _params) do
    vpses =
      Repo.all(
        from v in Vps,
          where: v.status != :deleted,
          order_by: [desc: v.inserted_at],
          limit: 1000,
          preload: [:region, :node]
      )

    json(conn, %{vpses: Enum.map(vpses, &vps_json/1)})
  end

  def vps_start(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.start_vps/1)
  def vps_stop(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.stop_vps/1)

  def vps_delete(conn, %{"id" => id}) do
    with_valid_vps(conn, id, fn vps_id ->
      case Provisioning.delete_vps(vps_id) do
        {:ok, _} -> json(conn, %{detail: "deleting"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(reason))
      end
    end)
  end

  # --- Nodes ---------------------------------------------------------------

  def nodes(conn, _params) do
    json(conn, %{nodes: Enum.map(Fleet.list_nodes(), &node_json/1)})
  end

  # --- helpers -------------------------------------------------------------

  defp vps_action(conn, id, fun) do
    with_valid_vps(conn, id, fn vps_id ->
      case fun.(vps_id) do
        {:ok, _} -> json(conn, %{detail: "ok"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(inspect(reason)))
      end
    end)
  end

  defp with_valid_vps(conn, id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, vps_id} -> fun.(vps_id)
      :error -> error(conn, :not_found, "not_found")
    end
  end

  defp vps_json(%Vps{} = v) do
    %{
      id: v.id,
      name: v.name,
      status: v.status,
      tier: v.tier,
      owner_email: v.owner_email,
      node: node_name(v),
      region: region_code(v),
      vcpu: v.vcpu,
      ram_mb: v.ram_mb,
      disk_gb: v.disk_gb,
      ip_address: v.ip_address,
      inserted_at: DateTime.to_iso8601(v.inserted_at)
    }
  end

  defp node_json(%Node{} = n) do
    %{
      id: n.id,
      name: n.name,
      tier: n.tier,
      status: n.status,
      owner_email: n.owner_email,
      region: region_code(n),
      total_vcpu: n.total_vcpu,
      total_ram_mb: n.total_ram_mb,
      total_disk_gb: n.total_disk_gb,
      available_vcpu: n.available_vcpu,
      available_ram_mb: n.available_ram_mb,
      available_disk_gb: n.available_disk_gb,
      last_heartbeat_at: n.last_heartbeat_at && DateTime.to_iso8601(n.last_heartbeat_at)
    }
  end

  defp node_name(%Vps{node: %Node{name: name}}), do: name
  defp node_name(_), do: nil

  defp region_code(%{region: %{code: code}}), do: code
  defp region_code(_), do: nil

  defp count_by(query, f) do
    Repo.all(from x in query, group_by: field(x, ^f), select: {field(x, ^f), count(x.id)})
    |> Map.new()
  end

  defp map_total(m), do: m |> Map.values() |> Enum.sum()

  defp parse_role(%{"role" => r}) when r in ["user", "operator", "admin"],
    do: {:ok, String.to_existing_atom(r)}

  defp parse_role(_), do: {:error, :invalid_role}

  defp parse_amount(%{"amount_cents" => v}) do
    cents =
      cond do
        is_integer(v) -> v
        is_binary(v) -> case Integer.parse(v) do
          {n, ""} -> n
          _ -> nil
        end
        true -> nil
      end

    if is_integer(cents) and cents != 0 and abs(cents) <= 10_000_000,
      do: {:ok, cents},
      else: {:error, :invalid_amount}
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0

  defp ok_or({:ok, v}, _err), do: {:ok, v}
  defp ok_or(:error, err), do: err

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: code})
  end
end
