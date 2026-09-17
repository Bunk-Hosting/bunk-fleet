defmodule ControlPlaneWeb.NodeController do
  @moduledoc """
  De nodes die de ingelogde gebruiker beheert, en hun instellingen.

  Los van het beheerpaneel: de eigenaar van een node is niet per se een
  beheerder van het platform. Iemand kan hardware neerzetten zonder ergens
  anders iets te mogen, en die persoon hoort zijn eigen machine te kunnen
  instellen — en verder niets.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node

  @doc "De nodes van de ingelogde gebruiker."
  def index(conn, _params) do
    nodes = Fleet.list_nodes_owned_by(conn.assigns.current_user)

    json(conn, %{nodes: Enum.map(nodes, &node_json/1)})
  end

  @doc """
  Wijzigt de instellingen van een node.

  Een node die niet van de beller is geeft 404 en geen 403: dat een node bestaat
  is zelf al iets wat een vreemde niet hoeft te weten.
  """
  def update_settings(conn, %{"id" => id} = params) do
    with {:ok, node_id} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         {:ok, node} <-
           Fleet.update_node_settings(node_id, conn.assigns.current_user, settings(params)) do
      json(conn, %{node: node_json(node)})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_settings", details: errors(changeset)})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  # Alleen de velden die de eigenaar mag zetten komen door. Het changeset zou de
  # rest ook weigeren, maar een allow-list hier maakt zichtbaar wat er bedoeld is.
  defp settings(params) do
    Map.take(params, Enum.map(Node.settings_fields(), &Atom.to_string/1))
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  @doc """
  Draagt een node over aan een andere gebruiker, of haalt de eigenaar eraf.

  Alleen de eigenaar zelf. Een beheerder kan een node die nog geen eigenaar
  heeft toewijzen -- zonder dat zou een node die met een beheerderstoken is
  ingeschreven er nooit een kunnen krijgen -- maar daarna gaat de eigenaar er
  alleen over.
  """
  def assign_owner(conn, %{"id" => id} = params) do
    with {:ok, node_id} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         {:ok, owner_id} <- parse_owner(params["owner_email"]),
         {:ok, node} <- Fleet.assign_node_owner(node_id, conn.assigns.current_user, owner_id) do
      json(conn, %{node: node_json(node)})
    else
      {:error, :unknown_user} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "unknown_user"})

      {:error, :invalid_owner} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_owner"})

      # Ook bij :forbidden een 404: dat een node bestaat is zelf al iets wat een
      # vreemde niet hoeft te weten.
      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  # Een e-mailadres en geen id: de eigenaar van een node heeft geen lijst van
  # gebruikers en hoort die ook niet te krijgen. nil en "" betekenen allebei
  # "haal de eigenaar eraf"; een adres zonder account wordt geweigerd in plaats
  # van stil als "geen eigenaar" gelezen.
  defp parse_owner(nil), do: {:ok, nil}

  defp parse_owner(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:ok, nil}

      email ->
        case Accounts.get_user_by_email(email) do
          %{id: id} -> {:ok, id}
          nil -> {:error, :unknown_user}
        end
    end
  end

  defp parse_owner(_raw), do: {:error, :invalid_owner}

  defp node_json(%Node{} = n) do
    %{
      id: n.id,
      name: n.name,
      status: n.status,
      hypervisor: n.hypervisor,
      total_vcpu: n.total_vcpu,
      total_ram_mb: n.total_ram_mb,
      total_disk_gb: n.total_disk_gb,
      available_vcpu: n.available_vcpu,
      available_ram_mb: n.available_ram_mb,
      available_disk_gb: n.available_disk_gb,
      reported_avail_vcpu: n.reported_avail_vcpu,
      reported_avail_ram_mb: n.reported_avail_ram_mb,
      reported_avail_disk_gb: n.reported_avail_disk_gb,
      agent_version: n.agent_version,
      capacity_error: n.capacity_error,
      drain_reason: n.drain_reason,
      last_heartbeat_at: n.last_heartbeat_at && DateTime.to_iso8601(n.last_heartbeat_at),
      settings: Map.take(n, Node.settings_fields())
    }
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}
end
