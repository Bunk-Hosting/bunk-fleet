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
  alias ControlPlane.Credits.{LedgerEntry, TopupRequest}

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
      # Serialize per-user so two concurrent charges can't both observe the full
      # balance and overspend the wallet (mark_topup_paid/cancel already lock).
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [:erlang.phash2({:wallet, user_id})])

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

  ## Top-up requests (self-service wallet funding; admin confirms receipt)

  @doc "Creates a pending top-up request with a unique payment reference."
  def create_topup_request(user_id, amount_cents) do
    %TopupRequest{}
    |> TopupRequest.changeset(%{user_id: user_id, amount_cents: amount_cents, reference: generate_reference(), status: :pending})
    |> Repo.insert()
  end

  def list_topup_requests(user_id, limit \\ 20) do
    Repo.all(
      from t in TopupRequest,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at],
        limit: ^limit
    )
  end

  @doc "All pending requests (admin queue), oldest first, with the user preloaded."
  def list_pending_topups do
    Repo.all(from t in TopupRequest, where: t.status == :pending, order_by: [asc: t.inserted_at], preload: [:user])
  end

  @doc "Number of still-pending top-up requests for a user (used to cap abuse)."
  def count_pending_topups(user_id) do
    Repo.aggregate(from(t in TopupRequest, where: t.user_id == ^user_id and t.status == :pending), :count)
  end

  @doc """
  Confirms a pending top-up (admin, after payment received): credits the wallet
  and marks the request paid, atomically. A non-pending request yields
  `{:error, :not_pending}` so a double-confirm can never double-credit.
  """
  def mark_topup_paid(id) do
    Repo.transaction(fn ->
      # Lock the row so two concurrent confirms can't both observe :pending and
      # credit the wallet twice (READ COMMITTED would otherwise allow it).
      case Repo.one(from t in TopupRequest, where: t.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %TopupRequest{status: :pending} = tr ->
          {:ok, _} = add_entry(tr.user_id, tr.amount_cents, "topup", "Tegoed bijgeboekt (" <> tr.reference <> ")")

          {:ok, tr} =
            tr
            |> Ecto.Changeset.change(status: :paid, paid_at: DateTime.truncate(DateTime.utc_now(), :second))
            |> Repo.update()

          tr

        _ ->
          Repo.rollback(:not_pending)
      end
    end)
  end

  @doc "Lets a user cancel their own still-pending request."
  def cancel_topup_request(user_id, id) do
    Repo.transaction(fn ->
      case Repo.one(from t in TopupRequest, where: t.id == ^id, lock: "FOR UPDATE") do
        %TopupRequest{user_id: ^user_id, status: :pending} = tr ->
          {:ok, tr} = tr |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()
          tr

        _ ->
          Repo.rollback(:not_cancellable)
      end
    end)
  end

  @doc "Creates a pending top-up backed by a Mollie payment, keyed on its id."
  def create_mollie_topup(user_id, amount_cents, mollie_payment_id) do
    %TopupRequest{}
    |> TopupRequest.changeset(%{
      user_id: user_id,
      amount_cents: amount_cents,
      reference: mollie_payment_id,
      mollie_payment_id: mollie_payment_id,
      status: :pending
    })
    |> Repo.insert()
  end

  @doc """
  Credits the wallet for a paid Mollie payment (idempotent via mark_topup_paid).
  When `paid_amount` (Mollie's `%{"value","currency"}`) is given, the settled
  amount must match the recorded request or it is rejected `:amount_mismatch`.
  """
  def mark_topup_paid_by_mollie_id(mollie_payment_id, paid_amount \\ nil) do
    case Repo.get_by(TopupRequest, mollie_payment_id: mollie_payment_id) do
      nil ->
        {:error, :not_found}

      %TopupRequest{} = tr ->
        if amount_matches?(tr, paid_amount),
          do: mark_topup_paid(tr.id),
          else: {:error, :amount_mismatch}
    end
  end

  @doc """
  Marks a pending top-up `:cancelled` by its Mollie id (payment expired/canceled/
  failed). Idempotent and guarded on `:pending`, so it frees the per-user pending
  cap without ever touching an already-paid credit.
  """
  def cancel_topup_by_mollie_id(mollie_payment_id) do
    {count, _} =
      from(t in TopupRequest,
        where: t.mollie_payment_id == ^mollie_payment_id and t.status == :pending
      )
      |> Repo.update_all(
        set: [status: :cancelled, updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  # No amount to check against → accept (back-compat / admin flow).
  defp amount_matches?(_tr, nil), do: true

  defp amount_matches?(%TopupRequest{amount_cents: cents}, %{"value" => value, "currency" => currency}) do
    currency == "EUR" and value == euro_string(cents)
  end

  defp amount_matches?(_tr, _), do: false

  # Integer cents -> Mollie's 2-decimal string, matching ControlPlane.Mollie.
  defp euro_string(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)}." <> (rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  defp generate_reference do
    rand = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    "BUNK-" <> rand
  end
end
