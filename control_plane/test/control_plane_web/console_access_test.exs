defmodule ControlPlaneWeb.ConsoleAccessTest do
  @moduledoc """
  Who may open a console, and on whose machine.

  A console session is a root shell. The path to one is two requests: the owner
  mints a ticket over the authenticated JSON API, then the browser redeems it on
  a WebSocket handshake that carries no Authorization header. Everything that
  decides whether the right person reaches the right machine happens before the
  upgrade, which is exactly the part these tests can reach.

  The refusals are all the same 401/404, on purpose: a caller who guesses a VPS
  id must not be able to tell "not yours" from "does not exist".
  """
  use ControlPlaneWeb.ConnCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Console.Tickets
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"

  defp user_fixture do
    email = "console-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp authed(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp vps_fixture(owner, attrs \\ %{}) do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "R"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(
      Map.merge(
        %{
          name: "v-#{System.unique_integer([:positive])}",
          region_id: region.id,
          node_id: node.id,
          owner_id: owner.id,
          owner_email: owner.email,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active,
          ip_address: "10.10.0.21"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "minting a ticket" do
    test "the owner of an active VPS gets one", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner)

      resp =
        conn
        |> authed(owner)
        |> post(~p"/api/v1/vpses/#{vps.id}/console-ticket")
        |> json_response(200)

      assert is_binary(resp["ticket"])
      assert byte_size(resp["ticket"]) == 43
    end

    test "a stranger asking for someone else's VPS is told it does not exist", %{conn: conn} do
      owner = user_fixture()
      stranger = user_fixture()
      vps = vps_fixture(owner)

      # 404, not 403: a 403 would confirm the id is real.
      assert conn
             |> authed(stranger)
             |> post(~p"/api/v1/vpses/#{vps.id}/console-ticket")
             |> json_response(404)
    end

    test "an anonymous caller gets nothing", %{conn: conn} do
      vps = vps_fixture(user_fixture())

      assert %{status: 401} = post(conn, ~p"/api/v1/vpses/#{vps.id}/console-ticket")
    end

    test "a VPS that is not running has no console", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner, %{status: :stopped})

      assert conn
             |> authed(owner)
             |> post(~p"/api/v1/vpses/#{vps.id}/console-ticket")
             |> json_response(409)
    end

    test "a VPS with no address yet has no console", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner, %{ip_address: nil})

      assert conn
             |> authed(owner)
             |> post(~p"/api/v1/vpses/#{vps.id}/console-ticket")
             |> json_response(409)
    end

    test "an id that is not an id is refused without touching the database", %{conn: conn} do
      owner = user_fixture()

      for bad <- ["not-a-uuid", "../../etc/passwd", "1 OR 1=1"] do
        assert conn
               |> authed(owner)
               |> post(~p"/api/v1/vpses/#{bad}/console-ticket")
               |> json_response(404)
      end
    end
  end

  describe "redeeming a ticket on the handshake" do
    test "no ticket at all is refused", %{conn: conn} do
      vps = vps_fixture(user_fixture())

      assert %{status: 401} = get(conn, ~p"/ws/console/#{vps.id}")
    end

    test "a ticket nobody minted is refused", %{conn: conn} do
      vps = vps_fixture(user_fixture())

      assert %{status: 401} =
               get(conn, ~p"/ws/console/#{vps.id}?ticket=#{Tickets.random_token()}")
    end

    test "a ticket for one VPS does not open another", %{conn: conn} do
      owner = user_fixture()
      mine = vps_fixture(owner)
      also_mine = vps_fixture(owner)

      ticket = Tickets.mint(mine.id, owner.id)

      # Same owner, same everything — but the ticket names one machine and the
      # handshake names another, and the binding is what counts.
      assert %{status: 401} = get(conn, ~p"/ws/console/#{also_mine.id}?ticket=#{ticket}")
    end

    test "a ticket minted for someone else's account does not open the VPS", %{conn: conn} do
      owner = user_fixture()
      attacker = user_fixture()
      vps = vps_fixture(owner)

      # The ticket carries a user_id, and the VPS is looked up scoped to it.
      ticket = Tickets.mint(vps.id, attacker.id)

      assert %{status: 401} = get(conn, ~p"/ws/console/#{vps.id}?ticket=#{ticket}")
    end

    test "a ticket is spent by the first handshake, valid or not", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner, %{status: :stopped})
      ticket = Tickets.mint(vps.id, owner.id)

      # This one fails on the VPS status, but it still redeemed the ticket. A
      # ticket that survived a failed handshake would be one an attacker could
      # keep retrying with.
      assert %{status: 401} = get(conn, ~p"/ws/console/#{vps.id}?ticket=#{ticket}")
      assert Tickets.redeem(ticket) == :error
    end

    test "a VPS that stopped between minting and connecting is refused", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner)
      ticket = Tickets.mint(vps.id, owner.id)

      {:ok, _} = vps |> Vps.changeset(%{status: :stopped}) |> Repo.update()

      # The ticket is still good; the machine is not. State is re-read at
      # handshake time rather than trusted from when the ticket was minted.
      assert %{status: 401} = get(conn, ~p"/ws/console/#{vps.id}?ticket=#{ticket}")
    end

    test "a deleted VPS is refused even with a fresh ticket", %{conn: conn} do
      owner = user_fixture()
      vps = vps_fixture(owner)
      ticket = Tickets.mint(vps.id, owner.id)
      {:ok, _} = vps |> Vps.changeset(%{status: :deleted}) |> Repo.update()

      assert %{status: 401} = get(conn, ~p"/ws/console/#{vps.id}?ticket=#{ticket}")
    end
  end

  describe "the node's half of the relay" do
    test "a node without an agent token cannot dial back", %{conn: conn} do
      assert %{status: 401} = get(conn, ~p"/v1/console-relay?token=anything")
    end
  end
end
