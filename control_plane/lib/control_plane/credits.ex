defmodule ControlPlane.Credits do
  @moduledoc """
  Prepaid customer credit wallet — the internal stand-in for a real payment
  provider (Mollie comes later). Each user's balance is the sum of a signed
  `ledger_entries` log (integer cents; positive = credit, negative = charge).

  New users receive a signup bonus; creating a VPS charges a flat monthly price
  by size. This is the *customer-facing* side only — internal cost accounting uses the
  separate per-resource-hour metering in `ControlPlane.Billing`.
  """
  import Ecto.Query

  require Logger
  alias ControlPlane.Clock
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Repo

  @signup_bonus_cents 1000
  @size_prices_cents %{"small" => 300, "medium" => 600, "large" => 1200}

  def signup_bonus_cents, do: @signup_bonus_cents
  def size_prices_cents, do: @size_prices_cents

  @doc "Current balance in cents (0 when the user has no entries)."
  @spec balance_cents(binary()) :: integer()
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

  @spec add_entry(binary(), integer(), String.t(), String.t() | nil, binary() | nil) ::
          {:ok, LedgerEntry.t()} | {:error, Ecto.Changeset.t()}
  def add_entry(user_id, amount_cents, kind, description, vps_id \\ nil) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{
      user_id: user_id,
      vps_id: vps_id,
      amount_cents: amount_cents,
      kind: kind,
      description: description
    })
    |> Repo.insert()
  end

  @doc """
  Ties a charge to the VPS it paid for, once that VPS exists.

  A charge is taken before the machine is created — the wallet has to be checked
  and debited before anything is provisioned — so for a moment the entry has no
  VPS. Stamping it here closes that window: from now on a `vps_charge` still
  carrying no `vps_id` after the grace period means the creation never happened,
  and `Credits.refund_orphan_charges/1` can give the money back without anyone
  reading timestamps.
  """
  @spec attach_vps(LedgerEntry.t() | nil, binary()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, Ecto.Changeset.t()}
  def attach_vps(nil, _vps_id), do: {:ok, nil}

  def attach_vps(%LedgerEntry{} = entry, vps_id) do
    entry |> LedgerEntry.changeset(%{vps_id: vps_id}) |> Repo.update()
  end

  @doc """
  Grants the one-time welcome credit, at most once per user.

  "One-time" is enforced against the ledger rather than assumed from the call
  site, because there are now two eras of account: users created before email
  confirmation existed were credited at registration and still have a NULL
  `confirmed_at`, so the moment one of them confirms their address,
  `Accounts.confirm_user/1` would hand them a second €10. Returns `{:ok, nil}`
  when a bonus is already on the ledger, which callers treat as success.
  """
  @spec grant_signup_bonus(binary()) :: {:ok, LedgerEntry.t() | :already_granted}
  def grant_signup_bonus(user_id) do
    already_granted? =
      Repo.exists?(
        from e in LedgerEntry, where: e.user_id == ^user_id and e.kind == "signup_bonus"
      )

    if already_granted? do
      {:ok, nil}
    else
      add_entry(user_id, @signup_bonus_cents, "signup_bonus", "Welkomstkrediet")
    end
  end

  @doc """
  Atomically charges `amount_cents` if the balance covers it. Returns
  `{:ok, entry}` or `{:error, :insufficient_credits}`. A zero/under charge is a
  no-op `{:ok, nil}` (free sizes never block creation).
  """
  @spec charge(binary(), integer(), String.t(), String.t()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, :insufficient_credits}
  def charge(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}

  def charge(user_id, amount_cents, kind, description) do
    Repo.transaction(fn ->
      # Serialize per-user so two concurrent charges can't both observe the full
      # balance and overspend the wallet (mark_topup_paid/cancel already lock).
      :ok = ControlPlane.Locks.take(Repo, :wallet, user_id)

      if balance_cents(user_id) >= amount_cents do
        {:ok, entry} = add_entry(user_id, -amount_cents, kind, description)
        entry
      else
        Repo.rollback(:insufficient_credits)
      end
    end)
  end

  # Charges written before ledger_entries had a vps_id all carry nil, and nil is
  # what this sweep reads as "the VPS never existed". Without this floor it would
  # look at every charge the platform ever took and refund the lot — which is
  # exactly what happened the first time it ran, before this line existed.
  #
  # The date is when the column shipped. It is a constant rather than a lookup
  # because it is a fact about history, and history does not change.
  @vps_id_since ~U[2026-09-13 20:00:00.000000Z]

  @doc """
  Refunds every `vps_charge` that never got a VPS, and reports how many.

  This is the one failure the create path cannot handle itself. It debits the
  wallet, then creates the machine, and it wraps that in a rescue and a catch so
  an exception or an exit still refunds — but nothing rescues a `:kill` or a node
  that loses power between the two. What is left behind is a charge with no VPS,
  and before this existed the only way to find one was a person comparing
  timestamps in the ledger.

  `grace_seconds` is what separates "never happened" from "happening right now":
  a create in flight also has no `vps_id` yet, and refunding that would hand back
  money for a VPS the customer is about to receive.
  """
  @spec refund_orphan_charges(non_neg_integer()) :: non_neg_integer()
  def refund_orphan_charges(grace_seconds \\ 600) do
    # Not Clock.shift/1: ledger_entries timestamps carry microseconds, because
    # two movements in the same second still have an order and money cares about
    # it. Clock is for the second-precision columns everywhere else.
    cutoff = DateTime.add(DateTime.utc_now(), -grace_seconds, :second)

    orphans =
      Repo.all(
        from e in LedgerEntry,
          where:
            e.kind == "vps_charge" and is_nil(e.vps_id) and e.inserted_at < ^cutoff and
              e.inserted_at > ^@vps_id_since and e.amount_cents < 0
      )

    Enum.each(orphans, fn entry ->
      # Stamped as refunded by tying it to nothing and changing its kind would
      # rewrite history; a ledger only ever grows. The counter-entry carries the
      # same absent vps_id, and `kind` says what it was for.
      {:ok, _} =
        add_entry(
          entry.user_id,
          -entry.amount_cents,
          "vps_refund",
          "Terugbetaling: de VPS is nooit aangemaakt"
        )

      # Mark the original so the next sweep does not refund it again. This is the
      # only mutation of a ledger row in the system, and it changes no amount.
      {:ok, _} = entry |> LedgerEntry.changeset(%{kind: "vps_charge_refunded"}) |> Repo.update()

      Logger.error(
        "refunded an orphaned vps_charge of #{abs(entry.amount_cents)} cents: " <>
          "the VPS it paid for was never created"
      )
    end)

    length(orphans)
  end

  @doc """
  Gives back what was charged for `vps_id`, once. Returns whether it found one.

  Idempotent by marking the original entry `vps_charge_refunded`: a sweep that
  runs every few seconds must not pay the same customer back on every tick.
  """
  @spec refund_charge_for_vps(binary()) :: boolean()
  def refund_charge_for_vps(vps_id) do
    case Repo.one(
           from e in LedgerEntry,
             where: e.vps_id == ^vps_id and e.kind == "vps_charge" and e.amount_cents < 0,
             limit: 1
         ) do
      nil ->
        false

      entry ->
        {:ok, _} =
          add_entry(
            entry.user_id,
            -entry.amount_cents,
            "vps_refund",
            "Terugbetaling: VPS-aanmaak mislukt",
            vps_id
          )

        {:ok, _} = entry |> LedgerEntry.changeset(%{kind: "vps_charge_refunded"}) |> Repo.update()
        true
    end
  end

  @doc "Credits an amount back (e.g. refund a failed provision)."
  @spec refund(binary(), integer(), String.t(), String.t()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, Ecto.Changeset.t()}
  def refund(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}

  def refund(user_id, amount_cents, kind, description),
    do: add_entry(user_id, amount_cents, kind, description)

  ## Top-up requests (self-service wallet funding; admin confirms receipt)

  @doc "Creates a pending top-up request with a unique payment reference."
  def create_topup_request(user_id, amount_cents) do
    %TopupRequest{}
    |> TopupRequest.changeset(%{
      user_id: user_id,
      amount_cents: amount_cents,
      reference: generate_reference(),
      status: :pending
    })
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
    Repo.all(
      from t in TopupRequest,
        where: t.status == :pending,
        order_by: [asc: t.inserted_at],
        preload: [:user]
    )
  end

  @doc "Number of still-pending top-up requests for a user (used to cap abuse)."
  @spec count_pending_topups(binary()) :: non_neg_integer()
  def count_pending_topups(user_id) do
    Repo.aggregate(
      from(t in TopupRequest, where: t.user_id == ^user_id and t.status == :pending),
      :count
    )
  end

  @doc """
  Confirms a pending top-up: credits the wallet and marks the request paid,
  atomically. A non-pending request yields `{:error, :not_pending}` so a
  double-confirm can never double-credit.

  `paid_via` legt vast wie de betaling bevestigde: `"mollie"` voor de webhook van
  de betaalprovider, `"manual"` voor een mens. Dat onderscheid bepaalt of het
  bedrag omzet is — zie `ControlPlane.Billing.Revenue` — en het is daarom een
  verplicht argument in plaats van iets met een voorkeurswaarde. Een nieuwe
  aanroeper moet die vraag beantwoorden, niet per ongeluk overslaan.
  """
  def mark_topup_paid(id, paid_via) when paid_via in ["mollie", "manual"] do
    Repo.transaction(fn ->
      # Lock the row so two concurrent confirms can't both observe :pending and
      # credit the wallet twice (READ COMMITTED would otherwise allow it).
      case Repo.one(from t in TopupRequest, where: t.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %TopupRequest{status: :pending} = tr ->
          {:ok, _} =
            add_entry(
              tr.user_id,
              tr.amount_cents,
              "topup",
              "Tegoed bijgeboekt (" <> tr.reference <> ")"
            )

          {:ok, tr} =
            tr
            |> Ecto.Changeset.change(
              status: :paid,
              paid_at: Clock.now(),
              paid_via: paid_via
            )
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
          do: mark_topup_paid(tr.id, "mollie"),
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
      |> Repo.update_all(set: [status: :cancelled, updated_at: Clock.now()])

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  # No amount to check against → accept (back-compat / admin flow).
  defp amount_matches?(_tr, nil), do: true

  defp amount_matches?(%TopupRequest{amount_cents: cents}, %{
         "value" => value,
         "currency" => currency
       }) do
    currency == "EUR" and value == euro_string(cents)
  end

  defp amount_matches?(_tr, _), do: false

  # Integer cents -> Mollie's 2-decimal string, matching ControlPlane.Mollie.
  defp euro_string(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)}." <>
      (rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  defp generate_reference do
    rand = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    "BUNK-" <> rand
  end
end
