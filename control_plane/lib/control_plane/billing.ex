defmodule ControlPlane.Billing do
  @moduledoc """
  Metering + operator-payout accounting for the fleet.

  ## Model (accrual via periodic snapshots)

  Each VPS, while `:active` and placed on a node, accrues usage on that node.
  We meter via periodic "meter ticks" (driven by `ControlPlane.Fleet.Reconciler`):
  on each tick, for every active VPS, we record the seconds elapsed since it was
  last metered together with its resource size into a `usage_records` row, and
  advance the VPS's `last_metered_at` watermark. Operator payouts then aggregate
  `usage_records` per node-operator (`owner_email`) over a time window. Because we
  record an immutable resource-size snapshot per slice, resizing a VPS later does
  not retroactively change already-accrued usage.

  ## Money units & precision

  Rates are configurable and intentionally NOT a hardcoded business price. They
  are expressed as money *per resource-hour* and represented as `Decimal` values:

    * `:vcpu`   — money per vCPU-hour
    * `:ram_gb` — money per GB-of-RAM-hour
    * `:disk_gb`— money per GB-of-disk-hour

  The unit of the `Decimal` (dollars, euros, credits, millicents, ...) is whatever
  the operator configures; this module only does the arithmetic and returns a
  `Decimal` in the same unit, rounded to `@money_scale` (6) decimal places.

  IMPORTANT: configure rates as **strings** (or integers / `Decimal`s) — never
  floats, which can't represent decimal money exactly. A float rate raises:

      config :control_plane, :billing_rates, %{
        vcpu: "0.012",
        ram_gb: "0.004",
        disk_gb: "0.0002"
      }

  Defaults are placeholders (see `@default_rates`) — set real rates in config.

  ### Why we divide once

  Naively computing `(seconds/3600) * rate` per record rounds twice per record at
  Decimal context precision, accumulating error and making per-record sums (used
  by `compute_payout/2`) disagree with grouped sums (`payout_summary/1`). Instead
  we accumulate an EXACT integer-scaled Decimal numerator per record and divide
  exactly once at the very end (by `3600 * 1024`, the seconds-per-hour times the
  MB-per-GB factor folded into the numerator), then round to `@money_scale`. Per
  record the exact numerator is:

      seconds * ( vcpu    * rate.vcpu  * 1024
                + ram_mb  * rate.ram_gb
                + disk_gb * rate.disk_gb * 1024 )

  so that `amount = round( Σ numerator / (3600 * 1024), @money_scale )`. Because
  every payout path folds the same exact numerators, `compute_payout/2` and
  `payout_summary/1` reconcile bit-for-bit.

  ## Concurrency / single-instance assumption

  Metering assumes a single control-plane instance runs `meter_active_vpses/1`.
  Within a node we serialize concurrent/overlapping meters by locking each VPS
  row `FOR UPDATE` before reading its watermark and inserting its slice. Across
  multiple control-plane instances you would additionally need a leader election
  or an advisory lock around the tick; the UNIQUE `(vps_id, metered_at)` index on
  `usage_records` is the data-layer guarantee that even then no time slice is
  ever billed twice.
  """
  import Ecto.Query, warn: false
  require Logger

  alias ControlPlane.Repo
  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.{Node, Vps}

  # Exact divisor folded into every per-record numerator: seconds→hours (3600)
  # times MB→GB (1024). Kept as an integer Decimal so the single final division
  # is the only rounding step. See the moduledoc ("Why we divide once").
  @money_divisor Decimal.new(3600 * 1024)

  # MB→GB conversion factor, folded into per-record numerators so the only
  # division is the single final one by @money_divisor.
  @mb_per_gb Decimal.new(1024)

  # Decimal places the returned money amount is rounded to.
  @money_scale 6

  # Placeholder rates. These are NOT a business price — override in config
  # (`config :control_plane, :billing_rates, %{...}`). Kept tiny and explicit so
  # an un-configured environment meters at a documented, zero rate rather than
  # crashing.
  @default_rates %{
    vcpu: Decimal.new("0"),
    ram_gb: Decimal.new("0"),
    disk_gb: Decimal.new("0")
  }

  @doc """
  Returns the configured resource-hour rates as a map of `Decimal`s with keys
  `:vcpu`, `:ram_gb`, `:disk_gb`. See the moduledoc for units.

  Any individual rate missing from config falls back to its `@default_rates`
  value. Rate values must be `Decimal`, integer, or a decimal string — a float
  rate raises `ArgumentError`, since floats can't represent money exactly.
  """
  def resource_hour_rates do
    configured = Application.get_env(:control_plane, :billing_rates, %{})

    @default_rates
    |> Map.merge(Map.take(configured, [:vcpu, :ram_gb, :disk_gb]))
    |> Map.new(fn {k, v} -> {k, to_decimal(k, v)} end)
  end

  @doc """
  Meters every `:active` VPS that is placed on a node, recording one
  `UsageRecord` per VPS for the time elapsed since it was last metered and
  advancing each VPS's `last_metered_at` watermark to `now`.

  For each such VPS, `seconds = now - (last_metered_at || inserted_at)`, clamped
  to be `>= 0` (a clock skew or a future watermark never produces negative
  usage). VPSes whose node has no `owner_email` are skipped (there is no operator
  to pay), and are left un-metered so they can be picked up once an owner is set.

  All metering runs inside a single transaction, and each candidate VPS is
  re-loaded `FOR UPDATE` before its watermark is read and advanced. That lock
  serializes concurrent/overlapping meterings of the same VPS, so two runs can
  never bill the same seconds twice; the UNIQUE `(vps_id, metered_at)` index is a
  hard backstop if a duplicate slice is ever attempted anyway. See the moduledoc
  ("Concurrency / single-instance assumption").

  Accepts an optional `now` (default `DateTime.utc_now()`) for deterministic
  testing. Returns the number of VPSes metered.
  """
  def meter_active_vpses(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    # Candidate ids only: select active, placed VPSes whose node has an operator.
    # We don't trust this snapshot's watermark — it's re-read under a row lock
    # inside the transaction below.
    candidates =
      Repo.all(
        from v in Vps,
          join: n in Node,
          on: n.id == v.node_id,
          where: v.status == :active and not is_nil(v.node_id) and not is_nil(n.owner_email),
          select: {v.id, n.owner_email}
      )

    {:ok, metered} =
      Repo.transaction(fn ->
        Enum.reduce(candidates, 0, fn {vps_id, owner_email}, count ->
          # Re-load + lock the VPS row so concurrent meters serialize here and the
          # watermark we read is the committed truth, not a stale snapshot.
          vps = Repo.one(from v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE")

          if meterable?(vps, now) do
            seconds = elapsed_seconds(vps, now)

            Repo.insert!(
              UsageRecord.changeset(%UsageRecord{}, %{
                vps_id: vps.id,
                node_id: vps.node_id,
                owner_email: owner_email,
                seconds: seconds,
                vcpu: vps.vcpu,
                ram_mb: vps.ram_mb,
                disk_gb: vps.disk_gb,
                metered_at: now
              })
            )

            # Advance the watermark on the locked row. A second meter at the same
            # `now` then computes 0 seconds (and would also hit the unique index).
            Repo.update_all(
              from(v in Vps, where: v.id == ^vps.id),
              set: [last_metered_at: now, updated_at: now]
            )

            count + 1
          else
            # The VPS changed state, lost its node, or was already metered at this
            # exact `now` between the candidate scan and acquiring its lock — skip.
            count
          end
        end)
      end)

    metered
  end

  # Re-validates a freshly-locked VPS is still billable for tick `now`: it must
  # still exist, be active and placed, AND not already carry this exact `now` as
  # its watermark (which would make this a duplicate same-tick slice). Skipping
  # the already-metered case keeps an accidental re-meter at the same `now` a
  # no-op instead of tripping the UNIQUE (vps_id, metered_at) index and aborting
  # the whole batch — that index remains the hard backstop against true races.
  defp meterable?(%Vps{status: :active, node_id: node_id, last_metered_at: last_metered_at}, now)
       when not is_nil(node_id) do
    is_nil(last_metered_at) or DateTime.compare(last_metered_at, now) != :eq
  end

  defp meterable?(_vps, _now), do: false

  @doc """
  Aggregates raw resource-usage for an operator over the half-open window
  `{from, to}` (records with `metered_at >= from and metered_at < to`).

  The window is half-open so adjacent windows tile without double-counting the
  record exactly on a boundary.

  Returns a map of resource-hours-equivalent integer sums (seconds * resource),
  handy for reporting/debugging the inputs that feed `compute_payout/2`:

      %{
        seconds: total_seconds,
        vcpu_seconds: Σ seconds * vcpu,
        ram_mb_seconds: Σ seconds * ram_mb,
        disk_gb_seconds: Σ seconds * disk_gb,
        records: count
      }
  """
  def usage_for_owner(owner_email, {from, to}) do
    row =
      Repo.one(
        from u in UsageRecord,
          where:
            u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at < ^to,
          select: %{
            seconds: coalesce(sum(u.seconds), 0),
            vcpu_seconds: coalesce(sum(fragment("? * ?", u.seconds, u.vcpu)), 0),
            ram_mb_seconds: coalesce(sum(fragment("? * ?", u.seconds, u.ram_mb)), 0),
            disk_gb_seconds: coalesce(sum(fragment("? * ?", u.seconds, u.disk_gb)), 0),
            records: count(u.id)
          }
      )

    row || %{seconds: 0, vcpu_seconds: 0, ram_mb_seconds: 0, disk_gb_seconds: 0, records: 0}
  end

  @doc """
  Computes the total payout owed to `owner_email` for usage in the half-open
  window `{from, to}` (`metered_at >= from and metered_at < to`).

  Returns a `Decimal` in the same money unit as the configured rates, rounded to
  `@money_scale` decimal places (see the moduledoc). The amount is:

      round( Σ_record numerator / (3600 * 1024), @money_scale )

  where each record's exact numerator is
  `seconds * (vcpu*rate.vcpu*1024 + ram_mb*rate.ram_gb + disk_gb*rate.disk_gb*1024)`.
  Numerators are summed exactly and divided exactly once, so this reconciles
  bit-for-bit with `payout_summary/1`.
  """
  def compute_payout(owner_email, {from, to}) do
    rates = resource_hour_rates()

    Repo.all(
      from u in UsageRecord,
        where:
          u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at < ^to,
        select: {u.seconds, u.vcpu, u.ram_mb, u.disk_gb}
    )
    |> sum_numerators(rates)
    |> finalize_amount()
  end

  @doc """
  Returns a per-operator payout summary for the half-open window `{from, to}`
  (`metered_at >= from and metered_at < to`).

  Lists one entry per operator that has any usage in the window:

      [%{owner_email: ..., amount: %Decimal{}, seconds: integer, records: integer}, ...]

  `amount` is a `Decimal` in the configured money unit (see the moduledoc),
  computed via the same exact-numerator/divide-once helper as `compute_payout/2`
  (so a per-operator amount here equals `compute_payout(owner, window)` exactly),
  ordered by descending amount then operator email for stable output.
  """
  def payout_summary({from, to}) do
    rates = resource_hour_rates()

    # Pull every billable record in the window once and fold per operator in
    # Elixir; this keeps the Decimal money math identical to compute_payout/2
    # (DB-side Decimal arithmetic across drivers is comparatively fiddly).
    Repo.all(
      from u in UsageRecord,
        where: u.metered_at >= ^from and u.metered_at < ^to,
        select: {u.owner_email, u.seconds, u.vcpu, u.ram_mb, u.disk_gb}
    )
    |> Enum.group_by(fn {owner_email, _s, _v, _r, _d} -> owner_email end)
    |> Enum.map(fn {owner_email, records} ->
      numerator =
        records
        |> Enum.map(fn {_owner, s, v, r, d} -> {s, v, r, d} end)
        |> sum_numerators(rates)

      seconds = Enum.reduce(records, 0, fn {_owner, s, _v, _r, _d}, acc -> acc + s end)

      %{
        owner_email: owner_email,
        amount: finalize_amount(numerator),
        seconds: seconds,
        records: length(records)
      }
    end)
    |> Enum.sort(&payout_order/2)
  end

  @doc """
  Customer-facing cost breakdown: what the owner of these VPSes is charged for
  usage in the half-open window `{from, to}` (`metered_at >= from and < to`).

  Where the operator-payout functions key off the *node operator's* `owner_email`,
  this keys off the *customer* who owns each VPS (`vpses.owner_id`), so a user sees
  only their own consumption. Returns:

      %{
        total_seconds: integer,
        total_cost: %Decimal{},                       # exact: summed over all records
        vpses: [%{vps_id: id, name: name, seconds: integer, cost: %Decimal{}}, ...]
      }

  `total_cost` is computed from the exact numerators of *all* records at once (one
  division), so it does not drift from the sum of the per-VPS amounts by rounding;
  the per-VPS `cost` figures are each individually rounded for display. VPSes are
  ordered by descending cost, ties broken by name.
  """
  def customer_usage(owner_id, {from, to}) do
    rates = resource_hour_rates()

    records =
      Repo.all(
        from u in UsageRecord,
          join: v in Vps,
          on: v.id == u.vps_id,
          where: v.owner_id == ^owner_id and u.metered_at >= ^from and u.metered_at < ^to,
          select: {u.vps_id, v.name, u.seconds, u.vcpu, u.ram_mb, u.disk_gb}
      )

    vpses =
      records
      # Group by vps_id alone so it's structurally "one line per VPS"; the name is
      # the same for every row of a given vps_id (one live `vpses` row per join).
      |> Enum.group_by(fn {vps_id, _name, _s, _v, _r, _d} -> vps_id end)
      |> Enum.map(fn {vps_id, [{_id, name, _s, _v, _r, _d} | _] = group} ->
        numerator = group |> Enum.map(fn {_id, _n, s, v, r, d} -> {s, v, r, d} end) |> sum_numerators(rates)
        seconds = Enum.reduce(group, 0, fn {_id, _n, s, _v, _r, _d}, acc -> acc + s end)
        %{vps_id: vps_id, name: name, seconds: seconds, cost: finalize_amount(numerator)}
      end)
      |> Enum.sort(&vps_cost_order/2)

    total_numerator =
      records |> Enum.map(fn {_id, _n, s, v, r, d} -> {s, v, r, d} end) |> sum_numerators(rates)

    total_seconds = Enum.reduce(records, 0, fn {_id, _n, s, _v, _r, _d}, acc -> acc + s end)

    %{total_seconds: total_seconds, total_cost: finalize_amount(total_numerator), vpses: vpses}
  end

  # Stable ordering for the customer breakdown: priciest VPS first, ties by name.
  defp vps_cost_order(%{cost: c1, name: n1}, %{cost: c2, name: n2}) do
    case Decimal.compare(c1, c2) do
      :gt -> true
      :lt -> false
      :eq -> n1 <= n2
    end
  end

  # Stable ordering for the summary: largest amount first, ties broken by email.
  defp payout_order(%{amount: a1, owner_email: e1}, %{amount: a2, owner_email: e2}) do
    case Decimal.compare(a1, a2) do
      :gt -> true
      :lt -> false
      :eq -> e1 <= e2
    end
  end

  # --- internal helpers -----------------------------------------------------

  # Sums the EXACT per-record numerators (no division, so no intermediate
  # rounding) for a list of `{seconds, vcpu, ram_mb, disk_gb}` tuples. Division
  # by `@money_divisor` and rounding happen once, in `finalize_amount/1`.
  defp sum_numerators(records, rates) do
    Enum.reduce(records, Decimal.new(0), fn record, acc ->
      Decimal.add(acc, record_numerator(record, rates))
    end)
  end

  # Exact numerator for one record (see moduledoc "Why we divide once"):
  #   seconds * (vcpu*rate.vcpu*1024 + ram_mb*rate.ram_gb + disk_gb*rate.disk_gb*1024)
  # The *1024 on vcpu/disk folds the MB→GB factor into the numerator so the only
  # division is the final one by 3600*1024.
  defp record_numerator({seconds, vcpu, ram_mb, disk_gb}, rates) do
    vcpu_term = Decimal.mult(Decimal.mult(Decimal.new(vcpu), rates.vcpu), @mb_per_gb)
    ram_term = Decimal.mult(Decimal.new(ram_mb), rates.ram_gb)
    disk_term = Decimal.mult(Decimal.mult(Decimal.new(disk_gb), rates.disk_gb), @mb_per_gb)

    per_hour_scaled = Decimal.add(Decimal.add(vcpu_term, ram_term), disk_term)

    Decimal.mult(Decimal.new(seconds), per_hour_scaled)
  end

  # Single division + rounding step shared by both payout paths so they reconcile
  # bit-for-bit.
  defp finalize_amount(numerator) do
    numerator
    |> Decimal.div(@money_divisor)
    |> Decimal.round(@money_scale)
  end

  # Seconds since this VPS was last metered, clamped to >= 0. Falls back to
  # inserted_at the first time a VPS is metered (last_metered_at is nil).
  defp elapsed_seconds(%Vps{last_metered_at: nil, inserted_at: inserted_at}, now) do
    clamp_non_negative(DateTime.diff(now, inserted_at, :second))
  end

  defp elapsed_seconds(%Vps{last_metered_at: last_metered_at}, now) do
    clamp_non_negative(DateTime.diff(now, last_metered_at, :second))
  end

  defp clamp_non_negative(seconds) when seconds < 0, do: 0
  defp clamp_non_negative(seconds), do: seconds

  # Coerces a configured rate to Decimal. Strings, integers and Decimals are
  # exact; floats are REJECTED because they can't represent decimal money exactly
  # (e.g. 0.1 is not 1/10 in binary float) — configure money as strings.
  defp to_decimal(_key, %Decimal{} = d), do: d
  defp to_decimal(_key, n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(_key, s) when is_binary(s), do: Decimal.new(s)

  defp to_decimal(key, n) when is_float(n) do
    raise ArgumentError,
          "billing_rates.#{key} is a float (#{inspect(n)}); configure money rates as " <>
            "strings (e.g. \"0.012\"), integers, or Decimal — floats can't represent " <>
            "decimal money exactly"
  end
end
