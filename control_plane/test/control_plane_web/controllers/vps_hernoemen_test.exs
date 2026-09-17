defmodule ControlPlaneWeb.VpsHernoemenTest do
  @moduledoc """
  Een VPS hernoemen.

  De naam die de klant ziet is iets anders dan de naam waaronder de gast op de
  hypervisor staat. Dat verschil is hier het hele punt: de agent herkent zijn
  machine aan die tweede, en toen die ooit alleen de klantnaam was nam de tweede
  klant met dezelfde naam op een node de draaiende VM van de eerste over -- de
  kritieke bevinding van juli. Hernoemen mag daar niet aan raken.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp gebruiker do
    email = "hernoem-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp vps(user, status \\ :active) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{status: :online, last_heartbeat_at: Clock.now()})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "Oude naam",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(%{
      status: status,
      provider_vm_id: "2001",
      node_id: node.id,
      owner_id: user.id
    })
    |> Repo.insert!()
  end

  test "de eigenaar hernoemt zijn VPS", %{conn: conn} do
    u = gebruiker()
    v = vps(u)

    resp =
      conn
      |> ingelogd(u)
      |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "Webserver productie"})
      |> json_response(200)

    assert resp["vps"]["name"] == "Webserver productie"
    assert Repo.get!(Vps, v.id).name == "Webserver productie"
  end

  test "de machine op de hypervisor blijft ongemoeid", %{conn: conn} do
    # Hier hangt het aan: de agent herkent zijn VM hieraan.
    u = gebruiker()
    v = vps(u)

    conn |> ingelogd(u) |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "Iets anders"})

    bijgewerkt = Repo.get!(Vps, v.id)
    assert bijgewerkt.provider_vm_id == v.provider_vm_id
    assert bijgewerkt.node_id == v.node_id
  end

  test "spaties aan de randen verdwijnen", %{conn: conn} do
    u = gebruiker()
    v = vps(u)

    conn |> ingelogd(u) |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "  Netjes  "})

    assert Repo.get!(Vps, v.id).name == "Netjes"
  end

  test "een lege naam wordt geweigerd", %{conn: conn} do
    u = gebruiker()
    v = vps(u)

    resp =
      conn
      |> ingelogd(u)
      |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "   "})
      |> json_response(422)

    assert resp["error"] == "invalid_vps"
    assert Repo.get!(Vps, v.id).name == "Oude naam"
  end

  test "een verwijderde VPS houdt zijn naam", %{conn: conn} do
    # Die draait nergens meer, en zijn naam staat nog in verbruiksregels en
    # facturen -- die horen te blijven zeggen wat ze toen zeiden.
    u = gebruiker()
    v = vps(u, :deleted)

    resp =
      conn
      |> ingelogd(u)
      |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "Alsnog anders"})
      |> json_response(409)

    assert resp["error"] == "invalid_status_deleted"
    assert Repo.get!(Vps, v.id).name == "Oude naam"
  end

  test "andermans VPS geeft 404 en verandert niets", %{conn: conn} do
    v = vps(gebruiker())

    conn
    |> ingelogd(gebruiker())
    |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "Gekaapt"})
    |> json_response(404)

    assert Repo.get!(Vps, v.id).name == "Oude naam"
  end

  test "zonder sessie: 401", %{conn: conn} do
    v = vps(gebruiker())

    assert conn |> patch(~p"/api/v1/vpses/#{v.id}", %{"name" => "X"}) |> json_response(401)
  end
end
