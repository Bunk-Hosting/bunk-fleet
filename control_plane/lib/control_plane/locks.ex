defmodule ControlPlane.Locks do
  @moduledoc """
  Named Postgres advisory locks.

  Advisory locks are just numbers, so two unrelated pieces of code that both hash
  something into the same space can end up sharing a lock. The consequence is not
  corruption — it is two operations that have nothing to do with each other
  serialising on one another, which is the kind of slowdown nobody ever traces
  back to its cause.

  `pg_advisory_xact_lock/2` takes two integers, so the first is used as a class:
  every purpose gets its own, and keys only ever collide with keys of the same
  kind. Within a class a collision is harmless — two nodes' address allocations
  taking turns is a wasted moment, not a wrong answer.

  All locks here are transaction-scoped. They are released when the transaction
  ends, whichever way it ends, so no code path can leak one.
  """

  # Adding a class? Give it a new number and never re-use an old one: a number
  # that used to mean something else is a lock that seems to work until the day
  # two versions of the release are running at once.
  @classes %{
    # Serialises address and port allocation on one node.
    node_allocation: 1,
    # Serialises "which subnet block is free" across the fleet.
    fleet_subnets: 2,
    # Serialises everything that reads a wallet balance and then spends against
    # it. Taken from more than one module on purpose — `Credits.charge/4` and
    # `Subscriptions.charge_and_advance/2` are the same critical section seen
    # from two places, and they only exclude each other while they name the same
    # class and the same key.
    wallet: 3,
    # Serialises the per-owner VPS quota check against the create that follows it.
    owner_quota: 4
  }

  @doc """
  Takes a transaction-scoped advisory lock of `class`, keyed on `key`.

  Must be called inside a transaction — outside one, Postgres takes and
  immediately releases it, which looks like it worked and protects nothing.
  """
  def take(repo, class, key \\ nil) when is_map_key(@classes, class) do
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@classes[class], key_int(key)])
    :ok
  end

  @doc false
  def classes, do: @classes

  # Any term becomes a lock key. phash2/1 stays inside 2^27, comfortably within
  # the int4 Postgres wants and always non-negative.
  defp key_int(nil), do: 0
  defp key_int(key), do: :erlang.phash2(key)
end
