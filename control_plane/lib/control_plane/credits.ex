defmodule ControlPlane.Credits do
  @moduledoc """
  Prepaid customer credit wallet — the internal stand-in for a real payment
  provider (Mollie comes later). Each user's balance is the sum of a signed
  `ledger_entries` log (integer cents; positive = credit, negative = charge).

  New users receive a signup bonus; creating a VPS charges a flat monthly price
  by size. This is the *customer-facing* side only — operator payouts use the
  separate per-resource-hour metering in `ControlPlane.Billing`.
  """
  import Ecto.Query
  alias ControlPlane.Repo
  alias ControlPlane.Credits.LedgerEntry

  @signup_bonus_cents 1000
  @size_prices_cents %{"small" => 300, "medium" => 600, "large" => 1200}

  def signup_bonus_cents, do: @signup_bonus_cents
  def size_prices_cents, do: @size_prices_cents
  def price_for_size(size), do: Map.get(@size_prices_cents, size)

  @doc "Current balance in cents (0 when the user has no entries)."
  def balance_cents(user_id) do
    Repo.one(
      from e in LedgerEntry,
        where: e.user_id == ^user_id,
        select: coalesce(sum(e.amount_cents), 0)
    ) || 0
  end

  @doc "Most recent ledger entries, newest first."
  def list_entries(user_id, limit \\ 20) do
    Repo.all(
      from e in LedgerEntry,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at],
        limit: ^limit
    )
  end

  def add_entry(user_id, amount_cents, kind, description) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{user_id: user_id, amount_cents: amount_cents, kind: kind, description: description})
    |> Repo.insert()
  end

  @doc "Grants the one-time welcome credit. Best-effort: never blocks registration."
  def grant_signup_bonus(user_id) do
    add_entry(user_id, @signup_bonus_cents, "signup_bonus", "Welkomstkrediet")
  end

  @doc """
  Atomically charges `amount_cents` if the balance covers it. Returns
  `{:ok, entry}` or `{:error, :insufficient_credits}`. A zero/under charge is a
  no-op `{:ok, nil}` (free sizes never block creation).
  """
  def charge(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}

  def charge(user_id, amount_cents, kind, description) do
    Repo.transaction(fn ->
      if balance_cents(user_id) >= amount_cents do
        {:ok, entry} = add_entry(user_id, -amount_cents, kind, description)
        entry
      else
        Repo.rollback(:insufficient_credits)
      end
    end)
  end

  @doc "Credits an amount back (e.g. refund a failed provision)."
  def refund(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}
  def refund(user_id, amount_cents, kind, description), do: add_entry(user_id, amount_cents, kind, description)
end
