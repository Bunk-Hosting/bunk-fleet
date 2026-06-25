defmodule ControlPlaneWeb.Admin.EnrollTokenController do
  @moduledoc """
  Operator/admin API for minting single-use node enroll tokens.

  `create` mints a token via `ControlPlane.Enrollment.create_enroll_token/1` and
  returns the plaintext token (shown only once) together with a ready-to-run
  `install` one-liner a node operator pastes onto a host to bootstrap `bunk-agent`.

  Protected by `ControlPlaneWeb.Plugs.AdminAuth` (shared-secret admin token).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Region

  @default_ttl_seconds 3600

  def create(conn, params) do
    with {:ok, %Region{} = region} <- resolve_region(params),
         {:ok, tier} <- parse_tier(params),
         ttl_seconds <- parse_ttl(params),
         {:ok, {plaintext, enroll_token}} <-
           Enrollment.create_enroll_token(%{
             region_id: region.id,
             tier: tier,
             ttl_seconds: ttl_seconds
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        enroll_token: plaintext,
        expires_at: enroll_token.expires_at,
        region: region.code,
        tier: tier,
        install: install_command(conn, plaintext)
      })
    else
      {:error, :region_not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "region_not_found"})

      {:error, :invalid_tier} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_tier"})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_enroll_token"})
    end
  end

  # Accepts either `region_id` (binary_id) or `region_code` (e.g. "nl-1").
  defp resolve_region(%{"region_id" => region_id}) when is_binary(region_id) do
    case Fleet.get_region!(region_id) do
      %Region{} = region -> {:ok, region}
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
  # Default tier matches the Node schema default.
  defp parse_tier(_params), do: {:ok, :community}

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_integer(ttl) and ttl > 0, do: ttl

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, _} when n > 0 -> n
      _ -> @default_ttl_seconds
    end
  end

  defp parse_ttl(_params), do: @default_ttl_seconds

  # A ready-to-run command a node operator pastes onto a host to bootstrap the
  # bunk-agent and enroll the node into this control plane.
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
      _ -> request_url(conn)
    end
  end

  defp request_url(conn) do
    "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
