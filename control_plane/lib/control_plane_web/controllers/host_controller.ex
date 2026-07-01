defmodule ControlPlaneWeb.HostController do
  @moduledoc """
  Self-service "become a host" surface for the customer dashboard.

  Onboarding a node makes a plain `:user` an `:operator` (a superset of `:user`),
  mirroring the former native host portal. These endpoints sit BEFORE
  `RequireOperator` (in the `:user_api` pipeline) precisely because their job is
  to let a non-operator opt in; the actual node/token/earnings endpoints stay
  role-gated under `/api/v1/operator/*`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.{Accounts, Fleet}

  # GET /api/v1/host/status — is the caller already a host?
  def status(conn, _params) do
    role = conn.assigns.current_user.role
    # is_admin lets the dashboard offer the datacenter-host (standard-location)
    # flow, which only admins may use.
    json(conn, %{is_host: role in [:operator, :admin], is_admin: role == :admin, role: role})
  end

  # POST /api/v1/host/activate — promote :user -> :operator (idempotent). The
  # caller's existing session token keeps working; ApiAuth re-reads the role on
  # every request, so the operator endpoints become reachable immediately.
  def activate(conn, _params) do
    case promote(conn.assigns.current_user) do
      {:ok, user} -> json(conn, %{is_host: true, role: user.role})
      {:error, _changeset} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "activation_failed"})
    end
  end

  # GET /api/v1/host/regions — regions a node can be onboarded into.
  def regions(conn, _params) do
    regions =
      Fleet.list_regions()
      |> Enum.filter(& &1.enabled)
      |> Enum.map(fn r -> %{id: r.id, code: r.code, name: r.name} end)

    json(conn, %{regions: regions})
  end

  defp promote(%{role: :user} = user), do: Accounts.update_user_role(user, :operator)
  defp promote(user), do: {:ok, user}
end
