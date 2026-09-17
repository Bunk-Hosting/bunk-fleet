defmodule ControlPlaneWeb.BackupNuTest do
  @moduledoc """
  Zelf een back-up starten, buiten het nachtelijke schema om.

  Dit ontbrak: back-ups liepen alleen automatisch. Het moment waarop een klant
  er een wil is juist vlak vóór iets engs, en dan is "vannacht" geen antwoord.
  De weigeringen zijn hier het interessante deel -- een knop die "ok" zegt
  terwijl er niets gebeurt is erger dan geen knop.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp gebruiker do
    email = "backup-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp node_met_status(status) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{status: status, last_heartbeat_at: Clock.now()})
    |> Repo.insert!()
  end

  defp vps(user, node, attrs \\ %{}) do
    basis = %{
      status: :active,
      provider_vm_id: "2001",
      node_id: node.id,
      owner_id: user.id
    }

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(Map.merge(basis, attrs))
    |> Repo.insert!()
  end

  test "de eigenaar start er een en er gaat een commando uit", %{conn: conn} do
    u = gebruiker()
    v = vps(u, node_met_status(:online))

    resp =
      conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(202)

    assert resp["backup"]["status"] == "running"
    assert Repo.exists?(from c in Command, where: c.vps_id == ^v.id and c.kind == :backup)
  end

  test "andermans VPS geeft 404 en start niets", %{conn: conn} do
    v = vps(gebruiker(), node_met_status(:online))

    conn |> ingelogd(gebruiker()) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(404)

    refute Repo.exists?(from b in VpsBackup, where: b.vps_id == ^v.id)
  end

  test "een tweede back-up naast een lopende wordt geweigerd", %{conn: conn} do
    # Twee vzdumps van dezelfde gast vechten om de schijf van de node.
    u = gebruiker()
    v = vps(u, node_met_status(:online))

    conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(202)

    resp = conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(409)
    assert resp["error"] == "backup_already_running"
    assert Repo.aggregate(from(b in VpsBackup, where: b.vps_id == ^v.id), :count) == 1
  end

  test "een offline node geeft 409 in plaats van een commando dat blijft liggen", %{conn: conn} do
    # Anders denkt de klant dat er een back-up is terwijl het commando in de
    # wachtrij ligt te wachten op een node die niet terugkomt.
    u = gebruiker()
    v = vps(u, node_met_status(:offline))

    resp = conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(409)
    assert resp["error"] == "node_unreachable"
  end

  test "een VPS die niet draait heeft niets te archiveren", %{conn: conn} do
    u = gebruiker()
    v = vps(u, node_met_status(:online), %{status: :stopped})

    resp = conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(409)
    assert resp["error"] == "not_provisioned"
  end

  test "zonder sessie: 401", %{conn: conn} do
    v = vps(gebruiker(), node_met_status(:online))

    assert conn |> post(~p"/api/v1/vpses/#{v.id}/backups") |> json_response(401)
  end
end
