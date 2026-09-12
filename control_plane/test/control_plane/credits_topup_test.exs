defmodule ControlPlane.CreditsTopupTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Credits

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Rookworst31!secure"})
    u
  end

  test "create request mints a unique reference and stays pending" do
    u = user("tu1@bunk.test")
    {:ok, r} = Credits.create_topup_request(u.id, 2500)
    assert r.status == :pending
    assert String.starts_with?(r.reference, "BUNK-")
    assert [^r] = Enum.filter(Credits.list_topup_requests(u.id), &(&1.id == r.id))
  end

  test "amount bounds are enforced" do
    u = user("tu2@bunk.test")
    assert {:error, _} = Credits.create_topup_request(u.id, 100)
    assert {:error, _} = Credits.create_topup_request(u.id, 200_000)
    assert {:ok, _} = Credits.create_topup_request(u.id, 500)
  end

  test "confirming a top-up credits the wallet exactly once" do
    u = user("tu3@bunk.test")
    start = Credits.balance_cents(u.id)
    {:ok, r} = Credits.create_topup_request(u.id, 2500)

    {:ok, paid} = Credits.mark_topup_paid(r.id)
    assert paid.status == :paid
    assert Credits.balance_cents(u.id) == start + 2500

    # idempotent: a second confirm must not double-credit
    assert {:error, :not_pending} = Credits.mark_topup_paid(r.id)
    assert Credits.balance_cents(u.id) == start + 2500
  end

  test "confirm unknown id -> not_found" do
    assert {:error, :not_found} = Credits.mark_topup_paid(Ecto.UUID.generate())
  end

  test "user can cancel their own pending request, not others'" do
    u = user("tu4@bunk.test")
    other = user("tu5@bunk.test")
    {:ok, r} = Credits.create_topup_request(u.id, 1000)
    assert {:error, :not_cancellable} = Credits.cancel_topup_request(other.id, r.id)
    assert {:ok, c} = Credits.cancel_topup_request(u.id, r.id)
    assert c.status == :cancelled
    # cancelled can't be paid
    assert {:error, :not_pending} = Credits.mark_topup_paid(r.id)
  end

  test "concurrent confirms credit the wallet only once" do
    u = user("tu6@bunk.test")
    start = Credits.balance_cents(u.id)
    {:ok, r} = Credits.create_topup_request(u.id, 2500)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Credits.mark_topup_paid(r.id) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Credits.balance_cents(u.id) == start + 2500
  end
end
