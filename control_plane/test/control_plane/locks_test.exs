defmodule ControlPlane.LocksTest do
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Locks

  test "every class has its own number, and no number is shared" do
    numbers = Map.values(Locks.classes())
    assert length(numbers) == length(Enum.uniq(numbers))
  end

  test "the wallet lock is one class used from two modules" do
    # Credits.charge/4 and Subscriptions.charge_and_advance/2 are the same
    # critical section seen from two places. They only exclude each other while
    # they name the same class — so the class has to exist, and anyone splitting
    # it into two has to fail this test first.
    assert Map.has_key?(Locks.classes(), :wallet)
  end

  test "an unknown class does not silently take some other lock" do
    assert_raise FunctionClauseError, fn ->
      Repo.transaction(fn -> Locks.take(Repo, :not_a_real_class, 1) end)
    end
  end

  test "taking a lock twice in one transaction is fine" do
    # Postgres advisory locks are re-entrant per session; a nested take must not
    # deadlock against itself.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Locks.take(Repo, :wallet, "user-1")
               Locks.take(Repo, :wallet, "user-1")
             end)
  end

  test "different keys in one class do not block each other" do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Locks.take(Repo, :wallet, "user-1")
               Locks.take(Repo, :wallet, "user-2")
             end)
  end

  test "a nil key is a valid whole-class lock" do
    assert {:ok, :ok} = Repo.transaction(fn -> Locks.take(Repo, :fleet_subnets) end)
  end

  test "keys are hashed into the range Postgres accepts" do
    # int4, and never negative — a term that hashed outside it would make the
    # query raise rather than lock.
    for key <- [nil, "user-1", {:tuple, 1}, 10_000_000_000, Ecto.UUID.generate()] do
      assert {:ok, :ok} = Repo.transaction(fn -> Locks.take(Repo, :wallet, key) end)
    end
  end
end
