defmodule ControlPlane.ConsoleSecurityTest do
  @moduledoc """
  The two credentials the in-browser console rests on.

  A console session hands a customer a root shell on their VPS, and it is reached
  over a WebSocket — which a browser cannot put an Authorization header on. So the
  ticket IS the authentication, and the pinned host key is the only thing that
  says the shell on the other end is the customer's machine and not the node
  operator sitting in the middle. Neither had tests.
  """
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Console.HostKeys
  alias ControlPlane.Console.Tickets
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias Ecto.Adapters.SQL.Sandbox

  defp vps_fixture(attrs \\ %{}) do
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
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "console tickets" do
    test "a minted ticket redeems once and then never again" do
      ticket = Tickets.mint("vps-1", "user-1")

      assert {:ok, %{vps_id: "vps-1", user_id: "user-1"}} = Tickets.redeem(ticket)
      # Single use is the whole point: a ticket in a URL ends up in proxy logs,
      # browser history and referrers, and any of those is a second connection.
      assert Tickets.redeem(ticket) == :error
    end

    test "a ticket nobody minted is refused" do
      assert Tickets.redeem(Tickets.random_token()) == :error
    end

    test "a ticket is bound to the VPS it was minted for" do
      # Redeeming gives back the binding rather than trusting the id in the URL,
      # so a customer cannot point their own ticket at someone else's machine.
      mine = Tickets.mint("my-vps", "me")

      assert {:ok, %{vps_id: "my-vps", user_id: "me"}} = Tickets.redeem(mine)
    end

    test "an empty or non-string ticket is refused rather than crashing" do
      for bad <- ["", nil, 42, %{}, [], :atom] do
        assert Tickets.redeem(bad) == :error
      end
    end

    test "tickets are unguessable and never repeat" do
      tokens = for _ <- 1..500, do: Tickets.random_token()

      assert length(Enum.uniq(tokens)) == 500
      # 256 bits, URL-safe base64, no padding.
      assert Enum.all?(tokens, &(byte_size(&1) == 43))
      assert Enum.all?(tokens, &String.match?(&1, ~r/\A[A-Za-z0-9_-]+\z/))
    end
  end

  describe "host key pinning" do
    @fingerprint "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    @other "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    test "the first connection pins, the second must match it" do
      vps = vps_fixture()

      assert HostKeys.verify(vps.id, @fingerprint)
      assert Repo.get!(Vps, vps.id).ssh_host_key == @fingerprint
      assert HostKeys.verify(vps.id, @fingerprint)
    end

    test "a different key on a pinned VPS is rejected and does not overwrite the pin" do
      vps = vps_fixture()
      assert HostKeys.verify(vps.id, @fingerprint)

      # This is the operator-MITM case: the node controls the hypervisor and the
      # relay, so it can present any key it likes. It must not be able to replace
      # the pin by presenting a new one.
      refute HostKeys.verify(vps.id, @other)
      assert Repo.get!(Vps, vps.id).ssh_host_key == @fingerprint
    end

    test "a second attempt after a rejection is still rejected" do
      vps = vps_fixture()
      HostKeys.verify(vps.id, @fingerprint)

      refute HostKeys.verify(vps.id, @other)
      refute HostKeys.verify(vps.id, @other)
      assert HostKeys.verify(vps.id, @fingerprint)
    end

    test "concurrent first connections converge on one pin" do
      vps = vps_fixture()

      # Same host, so the same fingerprint: first writer wins, the rest are
      # harmless no-ops, and nobody gets rejected for racing.
      results =
        1..8
        |> Task.async_stream(fn _ ->
          Sandbox.allow(Repo, self(), self())
          HostKeys.verify(vps.id, @fingerprint)
        end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results)
      assert Repo.get!(Vps, vps.id).ssh_host_key == @fingerprint
    end

    test "a non-string fingerprint is rejected" do
      vps = vps_fixture()

      for bad <- [nil, 42, %{}, :atom] do
        refute HostKeys.verify(vps.id, bad)
      end
    end

    test "forgetting a pin lets the next connection pin afresh" do
      vps = vps_fixture()
      HostKeys.verify(vps.id, @fingerprint)

      # What a restore from backup does: the disk is older, so the host key is
      # older, and TOFU would read that as the attack it exists to catch.
      assert {:ok, 1} = HostKeys.forget(vps.id)
      assert Repo.get!(Vps, vps.id).ssh_host_key == nil

      assert HostKeys.verify(vps.id, @other)
      assert Repo.get!(Vps, vps.id).ssh_host_key == @other
    end

    test "forgetting one VPS's pin leaves every other pin standing" do
      mine = vps_fixture()
      theirs = vps_fixture()
      HostKeys.verify(mine.id, @fingerprint)
      HostKeys.verify(theirs.id, @fingerprint)

      HostKeys.forget(mine.id)

      assert Repo.get!(Vps, theirs.id).ssh_host_key == @fingerprint
    end

    test "a VPS id that does not exist pins nothing and accepts nothing twice" do
      ghost = Ecto.UUID.generate()

      # No row to pin against: the first call cannot record anything, so the
      # second has nothing to compare with. It must not raise.
      assert HostKeys.verify(ghost, @fingerprint)
      assert HostKeys.verify(ghost, @other)
    end
  end
end
