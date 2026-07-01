defmodule ControlPlaneWeb.OperatorController do
  @moduledoc """
  Operator self-service API: an authenticated `:operator` (or `:admin`) onboards
  their own worker nodes and tracks what they've earned.

    * `POST /api/v1/operator/enroll-tokens` — mint an enroll token bound to the
      caller, plus a ready-to-run install one-liner. Nodes that redeem it inherit
      the caller as owner, so metering/payouts accrue to them.
    * `GET  /api/v1/operator/nodes` — the caller's own nodes.
    * `GET  /api/v1/operator/earnings?from=&to=` — the payout owed to the caller for
      usage their nodes hosted in the half-open window `[from, to)` (defaults to the
      last 30 days). Money is serialized as a string to preserve Decimal precision.

  Behind `ApiAuth` + `RequireOperator` (see the router's `operator_api` pipeline).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlaneWeb.TimeWindow
  import ControlPlaneWeb.ApiResponse

  alias ControlPlane.{Billing, Enrollment, Fleet}
  alias ControlPlane.Fleet.{Node, Region}

  @default_ttl_seconds 3600
  @max_ttl_seconds 86_400

  def create_enroll_token(conn, params) do
    user = conn.assigns.current_user

    with {:ok, %Region{} = region} <- resolve_region(params),
         {:ok, tier} <- parse_tier(user, params),
         {:ok, ttl_seconds} <- parse_ttl(params),
         {:ok, {plaintext, token}} <- mint_token(user, tier, region.id, ttl_seconds) do
      conn
      |> put_status(:created)
      |> json(%{
        enroll_token: plaintext,
        expires_at: token.expires_at,
        region: region.code,
        tier: tier,
        install: install_command(conn, plaintext)
      })
    else
      {:error, :region_not_found} -> error(conn, :unprocessable_entity, "region_not_found")
      {:error, :invalid_tier} -> error(conn, :unprocessable_entity, "invalid_tier")
      {:error, :invalid_ttl} -> error(conn, :unprocessable_entity, "invalid_ttl")
      {:error, _changeset} -> error(conn, :unprocessable_entity, "invalid_enroll_token")
    end
  end

  def nodes(conn, _params) do
    user = conn.assigns.current_user
    own = Fleet.list_nodes_for_owner(user.email)

    # Admins also manage the shared datacenter clusters (our standard locations),
    # visible to every admin regardless of which admin enrolled them.
    shared = if user.role == :admin, do: Fleet.list_datacenter_nodes(), else: []

    nodes = (own ++ shared) |> Enum.uniq_by(& &1.id) |> Enum.map(&node_json/1)
    json(conn, %{nodes: nodes})
  end

  def earnings(conn, params) do
    with {:ok, {from, to}} <- TimeWindow.parse(params) do
      email = conn.assigns.current_user.email
      amount = Billing.compute_payout(email, {from, to})
      usage = Billing.usage_for_owner(email, {from, to})

      json(conn, %{
        from: DateTime.to_iso8601(from),
        to: DateTime.to_iso8601(to),
        amount: Decimal.to_string(amount),
        seconds: usage.seconds,
        records: usage.records
      })
    else
      {:error, :invalid_datetime} -> error(conn, :bad_request, "invalid_datetime")
      {:error, :invalid_window} -> error(conn, :bad_request, "invalid_window")
    end
  end

  # --- helpers --------------------------------------------------------------

  defp node_json(%Node{} = node) do
    %{
      id: node.id,
      name: node.name,
      status: node.status,
      tier: node.tier,
      # Datacenter nodes are shared company clusters (no earnings); community
      # nodes belong to the operator and accrue payout.
      shared: node.tier == :datacenter,
      hypervisor: node.hypervisor,
      region: region_code(node),
      total_vcpu: node.total_vcpu,
      total_ram_mb: node.total_ram_mb,
      total_disk_gb: node.total_disk_gb,
      available_vcpu: node.available_vcpu,
      available_ram_mb: node.available_ram_mb,
      available_disk_gb: node.available_disk_gb,
      last_heartbeat_at: node.last_heartbeat_at
    }
  end

  defp region_code(%Node{region: %{code: code}}), do: code
  defp region_code(%Node{}), do: nil

  # Accepts either `region_id` (binary_id) or `region_code` (e.g. "nl-1").
  defp resolve_region(%{"region_id" => region_id}) when is_binary(region_id) do
    case Ecto.UUID.cast(region_id) do
      {:ok, id} ->
        case Fleet.get_region!(id) do
          %Region{} = region -> {:ok, region}
        end

      :error ->
        {:error, :region_not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :region_not_found}
  end

  defp resolve_region(%{"region_code" => region_code}) when is_binary(region_code) do
    case Fleet.region_by_code(region_code) do
      %Region{} = region -> {:ok, region}
      nil -> {:error, :region_not_found}
    end
  end

  defp resolve_region(_params), do: {:error, :region_not_found}

  # Admins may add trusted :datacenter hosts — our own server clusters, which are
  # never metered for payout and are shared across every admin. Every other
  # operator is limited to :community (bring-your-own) hardware they own and earn
  # credit for, so an operator-supplied tier is silently downgraded.
  defp parse_tier(%{role: :admin}, %{"tier" => "datacenter"}), do: {:ok, :datacenter}
  defp parse_tier(%{role: :admin}, %{"tier" => "community"}), do: {:ok, :community}
  defp parse_tier(%{role: :admin}, %{"tier" => _}), do: {:error, :invalid_tier}
  defp parse_tier(_user, _params), do: {:ok, :community}

  # A :datacenter token is company-owned: it carries no owner_email, so every admin
  # sees the resulting node and metering skips it. A :community token is owned by
  # the operator who minted it (their nodes' usage pays out to them).
  defp mint_token(_user, :datacenter, region_id, ttl_seconds) do
    Enrollment.create_enroll_token(%{
      region_id: region_id,
      tier: :datacenter,
      ttl_seconds: ttl_seconds
    })
  end

  defp mint_token(user, :community, region_id, ttl_seconds) do
    Enrollment.create_enroll_token_for_operator(user, %{
      region_id: region_id,
      tier: :community,
      ttl_seconds: ttl_seconds
    })
  end

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_integer(ttl) and ttl > 0 and ttl <= @max_ttl_seconds, do: {:ok, ttl}
  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_integer(ttl), do: {:error, :invalid_ttl}

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} when n > 0 and n <= @max_ttl_seconds -> {:ok, n}
      _ -> {:error, :invalid_ttl}
    end
  end

  defp parse_ttl(%{"ttl_seconds" => _}), do: {:error, :invalid_ttl}
  defp parse_ttl(_params), do: {:ok, @default_ttl_seconds}

  defp install_command(conn, token) do
    cp_url = control_plane_url(conn)

    # The interactive wizard handles both Proxmox and ESXi and runs on any Linux
    # VM that can reach the hypervisor API — far friendlier than a hand-built
    # docker one-liner, and it works for either hypervisor.
    "curl -fsSL #{cp_url}/install.sh | sudo bash -s -- --token #{token}"
  end

  defp control_plane_url(conn) do
    case Application.get_env(:control_plane, :public_url) do
      url when is_binary(url) and url != "" -> url
      _ -> "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
    end
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
