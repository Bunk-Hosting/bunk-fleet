defmodule ControlPlane.OrphanChargeTest do
  @moduledoc """
  Money taken for a VPS that never came into existence.

  The create path debits the wallet and then builds the machine, and it refunds
  on every failure it can observe — a returned error, a raised exception, even an
  exit. What nothing rescues is the process being killed outright, or the node
  losing power, in the moment between the two. Before the ledger knew about
  machines, what that left behind could only be found by a person comparing
  timestamps.
  """
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  @password "test-only-password-4f2b9c1e"

  defp user_fixture do
    email = "orphan-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, _} = Credits.add_entry(user.id, 10_000, "topup", "test")
    user
  end

  defp vps_fixture(user) do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "R"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      owner_id: user.id,
      owner_email: user.email,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :queued
    })
    |> Repo.insert!()
  end

  # Microseconds, because that is what the ledger stores — it is the one table
  # where two movements in the same second still need an order.
  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # A charge that was written some time ago and never got a VPS: exactly what a
  # kill between the debit and the create leaves behind.
  defp aged_orphan_charge(user, cents, seconds_ago) do
    {:ok, entry} = Credits.charge(user.id, cents, "vps_charge", "VPS Starter")

    entry
    |> Ecto.Changeset.change(%{inserted_at: ago(seconds_ago)})
    |> Repo.update!()
  end

  test "an old charge with no VPS behind it is refunded" do
    user = user_fixture()
    before = Credits.balance_cents(user.id)
    aged_orphan_charge(user, 500, 3600)

    assert Credits.balance_cents(user.id) == before - 500
    assert Credits.refund_orphan_charges(600) == 1
    assert Credits.balance_cents(user.id) == before
  end

  test "a charge from a create that is still in flight is left alone" do
    user = user_fixture()
    {:ok, _} = Credits.charge(user.id, 500, "vps_charge", "VPS Starter")

    # No vps_id yet because the create has not finished. Refunding here would
    # hand back money for a VPS the customer is about to receive.
    assert Credits.refund_orphan_charges(600) == 0
  end

  test "a charge that found its VPS is never touched" do
    user = user_fixture()
    vps = vps_fixture(user)
    entry = aged_orphan_charge(user, 500, 3600)
    {:ok, _} = Credits.attach_vps(entry, vps.id)

    assert Credits.refund_orphan_charges(600) == 0
  end

  test "the sweep does not pay the same customer twice" do
    user = user_fixture()
    before = Credits.balance_cents(user.id)
    aged_orphan_charge(user, 500, 3600)

    assert Credits.refund_orphan_charges(600) == 1
    # It runs on every reconciler tick; a second pass must find nothing.
    assert Credits.refund_orphan_charges(600) == 0
    assert Credits.balance_cents(user.id) == before
  end

  test "charges from before the ledger knew about VPSes are never touched" do
    # Every charge written before vps_id existed carries nil, and nil is what the
    # sweep reads as "the VPS never existed". Without a floor it refunds the
    # entire history of the platform — which is what it did the first time it ran
    # in production, giving three customers back money for VPSes they were using.
    user = user_fixture()
    before = Credits.balance_cents(user.id)
    {:ok, entry} = Credits.charge(user.id, 500, "vps_charge", "VPS Starter")

    entry
    |> Ecto.Changeset.change(%{inserted_at: ~U[2026-08-01 12:00:00.000000Z]})
    |> Repo.update!()

    assert Credits.refund_orphan_charges(600) == 0
    assert Credits.balance_cents(user.id) == before - 500
  end

  test "a top-up is not a charge and is never refunded" do
    user = user_fixture()
    {:ok, entry} = Credits.add_entry(user.id, 2500, "topup", "Bijgestort")
    entry |> Ecto.Changeset.change(%{inserted_at: ago(3600)}) |> Repo.update!()

    assert Credits.refund_orphan_charges(600) == 0
  end

  describe "a VPS that was queued but never dispatched" do
    test "gets its charge back automatically" do
      user = user_fixture()
      vps = vps_fixture(user)
      before = Credits.balance_cents(user.id)

      {:ok, entry} = Credits.charge(user.id, 750, "vps_charge", "VPS Starter")
      {:ok, _} = Credits.attach_vps(entry, vps.id)
      assert Credits.balance_cents(user.id) == before - 750

      assert Credits.refund_charge_for_vps(vps.id)
      assert Credits.balance_cents(user.id) == before
    end

    test "is only refunded once, however often the sweep runs" do
      user = user_fixture()
      vps = vps_fixture(user)
      before = Credits.balance_cents(user.id)
      {:ok, entry} = Credits.charge(user.id, 750, "vps_charge", "VPS Starter")
      {:ok, _} = Credits.attach_vps(entry, vps.id)

      assert Credits.refund_charge_for_vps(vps.id)
      refute Credits.refund_charge_for_vps(vps.id)
      assert Credits.balance_cents(user.id) == before
    end

    test "a VPS nobody was charged for reports that plainly" do
      user = user_fixture()
      vps = vps_fixture(user)

      refute Credits.refund_charge_for_vps(vps.id)
    end
  end

  test "the ledger only ever grows" do
    # A refund is a second entry, not an edit of the first. The only field that
    # changes on the original is its kind, so a sweep can tell it has been dealt
    # with; no amount is ever rewritten.
    user = user_fixture()
    aged_orphan_charge(user, 500, 3600)
    Credits.refund_orphan_charges(600)

    entries = Repo.all(from e in LedgerEntry, where: e.user_id == ^user.id)
    kinds = Enum.map(entries, & &1.kind) |> Enum.sort()

    assert "vps_charge_refunded" in kinds
    assert "vps_refund" in kinds
    assert Enum.any?(entries, &(&1.amount_cents == -500))
    assert Enum.any?(entries, &(&1.amount_cents == 500))
  end
end
