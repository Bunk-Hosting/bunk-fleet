defmodule ControlPlane.Billing do
  @moduledoc """
  Metering + internal cost accounting for the fleet.

  ## Model (accrual via periodic snapshots)

  Each VPS, while `:active` and placed on a node, accrues usage on that node.
  We meter via periodic "meter ticks" (driven by `ControlPlane.Fleet.Reconciler`):
  on each tick, for every active VPS, we record the seconds elapsed since it was
  last metered together with its resource size into a `usage_records` row, and
  advance the VPS's `last_metered_at` watermark. Internal cost reports then
  aggregate `usage_records` per node cost-centre (`owner_email`) over a time
  window, so we can see what each node's capacity actually served. Because we
  record an immutable resource-size snapshot per slice, resizing a VPS later does
  not retroactively change already-accrued usage.

  ## Money units & precision

  Rates are configurable and intentionally NOT a hardcoded business price. They
  are expressed as money *per resource-hour* and represented as `Decimal` values:

    * `:vcpu`   — money per vCPU-hour
    * `:ram_gb` — money per GB-of-RAM-hour
    * `:disk_gb`— money per GB-of-disk-hour

  The unit of the `Decimal` (dollars, euros, credits, millicents, ...) is whatever
  the deployment configures; this module only does the arithmetic and returns a
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
  by `resource_cost_for_owner/2`) disagree with grouped sums
  (`resource_cost_summary/1`). Instead
  we accumulate an EXACT integer-scaled Decimal numerator per record and divide
  exactly once at the very end (by `3600 * 1024`, the seconds-per-hour times the
  MB-per-GB factor folded into the numerator), then round to `@money_scale`. Per
  record the exact numerator is:

      seconds * ( vcpu    * rate.vcpu  * 1024
                + ram_mb  * rate.ram_gb
                + disk_gb * rate.disk_gb * 1024 )

  so that `amount = round( Σ numerator / (3600 * 1024), @money_scale )`. Because
  every cost path folds the same exact numerators, `resource_cost_for_owner/2`
  and `resource_cost_summary/1` reconcile bit-for-bit.

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

  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  # Exact divisor folded into every per-record numerator: seconds→hours (3600)
  # times MB→GB (1024). Kept as an integer Decimal so the single final division
  # is the only rounding step. See the moduledoc ("Why we divide once").
  @money_divisor Decimal.new(3600 * 1024)

  # MB→GB conversion factor, folded into per-record numerators so the only
  # division is the single final one by @money_divisor.
  @mb_per_gb Decimal.new(1024)

  # Decimal places the returned money amount is rounded to.
  @money_scale 6

  # A node whose last heartbeat is older than this (or not :online) is treated as
  # not delivering, so its VPSes are not metered.
  @meter_node_staleness_seconds 180

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
    # VPS ids whose teardown the operator is sitting on: once a stop/suspend/delete
    # command is in flight, metering pauses — removing the incentive to withhold
    # the result to keep earning on a VPS the customer believes is stopped.
    teardown_in_flight =
      from c in Command,
        where:
          c.kind in [:stop, :pause, :delete] and c.status in [:pending, :delivered] and
            not is_nil(c.vps_id),
        select: c.vps_id

    # Candidate {vps_id => cost_centre}: which node's capacity is carrying this
    # VPS. We resolve it here unlocked, then re-validate each VPS under a row lock
    # below. Don't accrue usage while the node is offline or has gone silent: a
    # VPS on a dead node isn't actually being delivered, so metering it would
    # overstate the capacity that node really provided. Require the node currently
    # :online AND heard from within the staleness window.
    node_cutoff = DateTime.add(now, -@meter_node_staleness_seconds, :second)

    owner_by_vps =
      Repo.all(
        from v in Vps,
          join: n in Node,
          on: n.id == v.node_id,
          # Every node is our own capacity now, so every node is metered. The
          # cost centre is the node's owner_email when set (which team/person
          # inside Bunk runs it), falling back to the node name so a node minted
          # without an owner still reports its consumption instead of vanishing
          # from the cost picture.
          where: v.status == :active and not is_nil(v.node_id),
          where: n.status == :online and n.last_heartbeat_at >= ^node_cutoff,
          where: v.id not in subquery(teardown_in_flight),
          select: {v.id, fragment("coalesce(nullif(?, ''), ?)", n.owner_email, n.name)}
      )
      |> Map.new()

    # Process in bounded batches of 1,000, each in its OWN short transaction. A
    # single insert_all over the whole active fleet blows Postgres's 65,535
    # bind-parameter cap above ~7k VPSes (a total metering outage), and locking
    # every active VPS at once stalls all provision / power / delete
    # finalisation for the entire tick. The UNIQUE (vps_id, metered_at)
    # index keeps each batch double-bill safe on its own.
    owner_by_vps
    |> Map.keys()
    |> Enum.chunk_every(1_000)
    |> Enum.reduce(0, fn ids, acc -> acc + meter_batch(ids, owner_by_vps, now) end)
  end

  defp meter_batch(ids, owner_by_vps, now) do
    {:ok, metered} =
      Repo.transaction(fn ->
        # Lock this batch's rows (ascending id = deterministic, deadlock-free) so
        # the watermark we read is committed truth and concurrent meters serialise.
        locked = Repo.all(from v in Vps, where: v.id in ^ids, order_by: v.id, lock: "FOR UPDATE")

        # One row per still-meterable VPS; seconds computed in Elixir (elapsed_seconds
        # + the meterable? re-check on the locked row). insert_all bypasses the
        # changeset, so timestamps are explicit.
        rows =
          for vps <- locked, meterable?(vps, now) do
            %{
              vps_id: vps.id,
              node_id: vps.node_id,
              owner_email: Map.fetch!(owner_by_vps, vps.id),
              seconds: elapsed_seconds(vps, now),
              vcpu: vps.vcpu,
              ram_mb: vps.ram_mb,
              disk_gb: vps.disk_gb,
              metered_at: now,
              inserted_at: now,
              updated_at: now
            }
          end

        metered_ids = Enum.map(rows, & &1.vps_id)

        # on_conflict :nothing turns the UNIQUE (vps_id, metered_at) backstop into a
        # silent no-op for an accidental same-tick re-meter, so a duplicate slice
        # can never double-bill.
        unless rows == [] do
          Repo.insert_all(UsageRecord, rows,
            on_conflict: :nothing,
            conflict_target: [:vps_id, :metered_at]
          )

          Repo.update_all(
            from(v in Vps, where: v.id in ^metered_ids),
            set: [last_metered_at: now, updated_at: now]
          )
        end

        length(rows)
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
  handy for reporting/debugging the inputs that feed `resource_cost_for_owner/2`:

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
          where: u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at < ^to,
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
  Computes the total resource cost attributed to `owner_email` (a node cost
  centre) for usage in the half-open window `{from, to}` (`metered_at >= from and metered_at < to`).

  Returns a `Decimal` in the same money unit as the configured rates, rounded to
  `@money_scale` decimal places (see the moduledoc). The amount is:

      round( Σ_record numerator / (3600 * 1024), @money_scale )

  where each record's exact numerator is
  `seconds * (vcpu*rate.vcpu*1024 + ram_mb*rate.ram_gb + disk_gb*rate.disk_gb*1024)`.
  Numerators are summed exactly and divided exactly once, so this reconciles
  bit-for-bit with `resource_cost_summary/1`.
  """
  def resource_cost_for_owner(owner_email, {from, to}) do
    rates = resource_hour_rates()

    Repo.one(
      from u in UsageRecord,
        where: u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at < ^to,
        select: %{
          sv: sum(fragment("?::bigint * ?::bigint", u.seconds, u.vcpu)),
          sr: sum(fragment("?::bigint * ?::bigint", u.seconds, u.ram_mb)),
          sd: sum(fragment("?::bigint * ?::bigint", u.seconds, u.disk_gb))
        }
    )
    |> aggregate_numerator(rates)
    |> finalize_amount()
  end

  @doc """
  Returns a per-cost-centre resource summary for the half-open window
  `{from, to}` (`metered_at >= from and metered_at < to`).

  Lists one entry per node cost-centre that has any usage in the window:

      [%{owner_email: ..., amount: %Decimal{}, seconds: integer, records: integer}, ...]

  `amount` is a `Decimal` in the configured money unit (see the moduledoc),
  computed via the same exact-numerator/divide-once helper as
  `resource_cost_for_owner/2` (so a per-cost-centre amount here equals
  `resource_cost_for_owner(owner, window)` exactly), ordered by descending amount
  then cost-centre email for stable output.
  """
  def resource_cost_summary({from, to}) do
    rates = resource_hour_rates()

    # Aggregate per cost-centre in SQL: the exact integer sums Σ(seconds*resource)
    # come back grouped, and only the (exact) Decimal money math runs in Elixir.
    # This reconciles bit-for-bit with resource_cost_for_owner/2 because the per-record
    # numerator distributes — Σ s*(v*Rv*1024 + r*Rg + d*Rd*1024) equals
    # Rv*1024*Σ(s*v) + Rg*Σ(s*r) + Rd*1024*Σ(s*d) — and the rates/divide-once are
    # applied identically (see aggregate_numerator/2).
    Repo.all(
      from u in UsageRecord,
        where: u.metered_at >= ^from and u.metered_at < ^to,
        group_by: u.owner_email,
        select: %{
          owner_email: u.owner_email,
          sv: sum(fragment("?::bigint * ?::bigint", u.seconds, u.vcpu)),
          sr: sum(fragment("?::bigint * ?::bigint", u.seconds, u.ram_mb)),
          sd: sum(fragment("?::bigint * ?::bigint", u.seconds, u.disk_gb)),
          seconds: sum(u.seconds),
          records: count(u.id)
        }
    )
    |> Enum.map(fn row ->
      %{
        owner_email: row.owner_email,
        amount: row |> aggregate_numerator(rates) |> finalize_amount(),
        seconds: row.seconds,
        records: row.records
      }
    end)
    |> Enum.sort(&cost_order/2)
  end

  @doc """
  Customer-facing cost breakdown: what the owner of these VPSes is charged for
  usage in the half-open window `{from, to}` (`metered_at >= from and < to`).

  Where the internal cost functions key off the *node cost-centre's* `owner_email`,
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

    # One grouped row per VPS, summed in SQL. `name` is functionally dependent on
    # vps_id (one live `vpses` row per join), so grouping by both is equivalent to
    # the old group-by-vps_id-alone.
    rows =
      Repo.all(
        from u in UsageRecord,
          join: v in Vps,
          on: v.id == u.vps_id,
          where: v.owner_id == ^owner_id and u.metered_at >= ^from and u.metered_at < ^to,
          group_by: [u.vps_id, v.name],
          select: %{
            vps_id: u.vps_id,
            name: v.name,
            sv: sum(fragment("?::bigint * ?::bigint", u.seconds, u.vcpu)),
            sr: sum(fragment("?::bigint * ?::bigint", u.seconds, u.ram_mb)),
            sd: sum(fragment("?::bigint * ?::bigint", u.seconds, u.disk_gb)),
            seconds: sum(u.seconds)
          }
      )

    vpses =
      rows
      |> Enum.map(fn row ->
        %{
          vps_id: row.vps_id,
          name: row.name,
          seconds: row.seconds,
          cost: row |> aggregate_numerator(rates) |> finalize_amount()
        }
      end)
      |> Enum.sort(&vps_cost_order/2)

    # Total over ALL records via one division: sum the per-VPS integer sums (exact)
    # then finalize once, so the total never drifts from the per-VPS figures by
    # more than each VPS's own display rounding — identical to the old behaviour.
    totals =
      Enum.reduce(rows, %{sv: 0, sr: 0, sd: 0, seconds: 0}, fn r, acc ->
        %{
          sv: Decimal.add(to_dec(acc.sv), to_dec(r.sv)),
          sr: Decimal.add(to_dec(acc.sr), to_dec(r.sr)),
          sd: Decimal.add(to_dec(acc.sd), to_dec(r.sd)),
          seconds: acc.seconds + (r.seconds || 0)
        }
      end)

    %{
      total_seconds: totals.seconds,
      total_cost: totals |> aggregate_numerator(rates) |> finalize_amount(),
      vpses: vpses
    }
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
  defp cost_order(%{amount: a1, owner_email: e1}, %{amount: a2, owner_email: e2}) do
    case Decimal.compare(a1, a2) do
      :gt -> true
      :lt -> false
      :eq -> e1 <= e2
    end
  end

  # --- internal helpers -----------------------------------------------------

  # Exact numerator from the SQL-aggregated integer sums (see moduledoc "Why we
  # divide once"). Given sv=Σ(seconds*vcpu), sr=Σ(seconds*ram_mb),
  # sd=Σ(seconds*disk_gb), the total numerator is the distributed form of the
  # per-record sum:
  #   Rv*1024*sv + Rg*sr + Rd*1024*sd
  # so the only division is the final one by 3600*1024. Decimal mult/add are exact
  # (no rounding for realistic magnitudes), so this reconciles bit-for-bit with the
  # old per-record fold. A `nil` map (no rows for an aggregate query) and nil sums
  # (a group with no matching rows) both fold to 0 via `to_dec/1`.
  defp aggregate_numerator(nil, _rates), do: Decimal.new(0)

  defp aggregate_numerator(%{sv: sv, sr: sr, sd: sd}, rates) do
    vcpu_term = Decimal.mult(Decimal.mult(to_dec(sv), rates.vcpu), @mb_per_gb)
    ram_term = Decimal.mult(to_dec(sr), rates.ram_gb)
    disk_term = Decimal.mult(Decimal.mult(to_dec(sd), rates.disk_gb), @mb_per_gb)

    Decimal.add(Decimal.add(vcpu_term, ram_term), disk_term)
  end

  # SUM over a bigint expression comes back as a Decimal (Postgres numeric); a
  # group/window with no rows yields nil. Normalise both to a Decimal.
  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(i) when is_integer(i), do: Decimal.new(i)

  # Single division + rounding step shared by both cost paths so they reconcile
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
