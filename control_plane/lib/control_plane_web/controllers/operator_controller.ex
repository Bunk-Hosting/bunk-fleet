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

  alias ControlPlane.{Billing, Enrollment, Fleet}
  alias ControlPlane.Fleet.{Node, Region}

  @default_ttl_seconds 3600
  @max_ttl_seconds 86_400
  @default_window_days 30

  def create_enroll_token(conn, params) do
    with {:ok, %Region{} = region} <- resolve_region(params),
         {:ok, tier} <- parse_tier(params),
         {:ok, ttl_seconds} <- parse_ttl(params),
         {:ok, {plaintext, token}} <-
           Enrollment.create_enroll_token_for_operator(conn.assigns.current_user, %{
             region_id: region.id,
             tier: tier,
             ttl_seconds: ttl_seconds
           }) do
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
    nodes =
      conn.assigns.current_user.email
      |> Fleet.list_nodes_for_owner()
      |> Enum.map(&node_json/1)

    json(conn, %{nodes: nodes})
  end

  def earnings(conn, params) do
    with {:ok, to} <- parse_datetime(params["to"], default_to()),
         {:ok, from} <- parse_datetime(params["from"], default_from(to)),
         :ok <- validate_window(from, to) do
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

  defp parse_tier(%{"tier" => tier}) when tier in ["datacenter", "community"] do
    {:ok, String.to_existing_atom(tier)}
  end

  defp parse_tier(%{"tier" => _}), do: {:error, :invalid_tier}
  defp parse_tier(_params), do: {:ok, :community}

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

  defp default_to, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp default_from(to), do: DateTime.add(to, -@default_window_days * 24 * 3600, :second)

  defp parse_datetime(nil, default), do: {:ok, default}

  defp parse_datetime(value, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value, _default), do: {:error, :invalid_datetime}

  defp validate_window(from, to) do
    if DateTime.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_window}
  end

  defp install_command(conn, token) do
    cp_url = control_plane_url(conn)

    "docker run -d --name bunk-agent --restart unless-stopped " <>
      "-e BUNK_CONTROL_PLANE_URL=#{cp_url} " <>
      "-e BUNK_ENROLL_TOKEN=#{token} " <>
      "-e BUNK_HYPERVISOR=proxmox " <>
      "-e BUNK_PROXMOX_HOST=https://YOUR-PROXMOX:8006 " <>
      "-e BUNK_PROXMOX_NODE=YOUR-NODE " <>
      "-e BUNK_PROXMOX_TOKEN_ID=... " <>
      "-e BUNK_PROXMOX_TOKEN_SECRET=... " <>
      "ghcr.io/bunk-hosting/bunk-agent:latest"
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

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
