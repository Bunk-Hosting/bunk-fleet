defmodule ControlPlaneWeb.RegionControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp region(code) do
    %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()
  end

  defp node_in(region, attrs \\ %{}) do
    defaults = %{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
      total_vcpu: 16,
      total_ram_mb: 32_768,
      total_disk_gb: 500,
      available_vcpu: 16,
      available_ram_mb: 32_768,
      available_disk_gb: 500
    }

    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp auth(conn, user) do
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  setup do
    %{user: confirmed_user_fixture("regions@example.com")}
  end

  test "requires authentication", %{conn: conn} do
    assert conn |> get(~p"/api/v1/regions") |> json_response(401)
  end

  test "lists regions that have an online node with capacity", %{conn: conn, user: user} do
    open = region("nl-open-#{System.unique_integer([:positive])}")
    node_in(open)

    assert %{"regions" => regions} =
             conn |> auth(user) |> get(~p"/api/v1/regions") |> json_response(200)

    assert Enum.any?(regions, &(&1["code"] == open.code))
  end

  test "a region with no node behind it is not offered", %{conn: conn, user: user} do
    empty = region("nl-empty-#{System.unique_integer([:positive])}")

    %{"regions" => regions} = conn |> auth(user) |> get(~p"/api/v1/regions") |> json_response(200)

    refute Enum.any?(regions, &(&1["code"] == empty.code))
  end

  test "a region whose only node is full is not offered", %{conn: conn, user: user} do
    # Listing it would let someone pick a location we cannot deliver.
    full = region("nl-full-#{System.unique_integer([:positive])}")
    node_in(full, %{available_vcpu: 0, available_ram_mb: 0, available_disk_gb: 0})

    %{"regions" => regions} = conn |> auth(user) |> get(~p"/api/v1/regions") |> json_response(200)

    refute Enum.any?(regions, &(&1["code"] == full.code))
  end

  test "a region whose only node went offline is not offered", %{conn: conn, user: user} do
    stale = region("nl-stale-#{System.unique_integer([:positive])}")
    old = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    node_in(stale, %{last_heartbeat_at: old})

    %{"regions" => regions} = conn |> auth(user) |> get(~p"/api/v1/regions") |> json_response(200)

    refute Enum.any?(regions, &(&1["code"] == stale.code))
  end
end
