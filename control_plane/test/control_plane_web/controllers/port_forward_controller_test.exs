defmodule ControlPlaneWeb.PortForwardControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.PortPool
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp enrolled_node(region) do
    {:ok, {plaintext, _}} =
      Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: 3600})

    {:ok, %{node: node, agent_token: agent_token}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox"})

    node =
      node
      |> Node.changeset(%{public_host: "node.example.test"})
      |> Repo.update!()

    {node, agent_token}
  end

  defp vps(region, node, attrs \\ %{}) do
    %Vps{}
    |> Vps.changeset(
      Map.merge(
        %{
          name: "v-#{System.unique_integer([:positive])}",
          region_id: region.id,
          node_id: node.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active,
          ip_address: "10.10.0.#{20 + System.unique_integer([:positive])}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "requires a node token", %{conn: conn} do
    assert conn |> get(~p"/v1/port-forwards") |> json_response(401)
  end

  test "returns this node's forwards with the address to send them to", %{conn: conn} do
    r = region()
    {node, token} = enrolled_node(r)
    machine = vps(r, node, %{ip_address: "10.10.0.55"})
    {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: machine.id, target_port: 22})

    assert %{"forwards" => [forward]} =
             conn |> auth(token) |> get(~p"/v1/port-forwards") |> json_response(200)

    assert forward["target_ip"] == "10.10.0.55"
    assert forward["target_port"] == 22
    assert forward["protocol"] == "tcp"
    assert is_integer(forward["public_port"])
  end

  test "a node is never told about another node's forwards", %{conn: conn} do
    r = region()
    {mine, token} = enrolled_node(r)
    {theirs, _} = enrolled_node(r)

    {:ok, _} = PortPool.allocate(Repo, theirs, %{vps_id: vps(r, theirs).id, target_port: 22})

    assert %{"forwards" => []} =
             conn |> auth(token) |> get(~p"/v1/port-forwards") |> json_response(200)

    {:ok, _} = PortPool.allocate(Repo, mine, %{vps_id: vps(r, mine).id, target_port: 22})

    assert %{"forwards" => [_one]} =
             conn |> auth(token) |> get(~p"/v1/port-forwards") |> json_response(200)
  end

  test "a torn-down VPS is not a hole to keep open", %{conn: conn} do
    r = region()
    {node, token} = enrolled_node(r)
    machine = vps(r, node)
    {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: machine.id, target_port: 22})

    {:ok, _} = machine |> Vps.changeset(%{status: :deleted}) |> Repo.update()

    assert %{"forwards" => []} =
             conn |> auth(token) |> get(~p"/v1/port-forwards") |> json_response(200)
  end

  test "a VPS with no address yet is skipped rather than sent as a null target", %{conn: conn} do
    r = region()
    {node, token} = enrolled_node(r)
    machine = vps(r, node, %{ip_address: nil, status: :queued})
    {:ok, _} = PortPool.allocate(Repo, node, %{vps_id: machine.id, target_port: 22})

    assert %{"forwards" => []} =
             conn |> auth(token) |> get(~p"/v1/port-forwards") |> json_response(200)
  end
end
