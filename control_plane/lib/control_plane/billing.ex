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

  ## Money units

  Rates are configurable and intentionally NOT a hardcoded business price. They
  are expressed as money *per resource-hour* and represented as `Decimal` values:

    * `:vcpu`   — money per vCPU-hour
    * `:ram_gb` — money per GB-of-RAM-hour
    * `:disk_gb`— money per GB-of-disk-hour

  The unit of the `Decimal` (dollars, euros, credits, millicents, ...) is whatever
  the operator configures; this module only does the arithmetic and returns a
  `Decimal` in the same unit. Configure via:

      config :control_plane, :billing_rates, %{
        vcpu: Decimal.new("0.012"),
        ram_gb: Decimal.new("0.004"),
        disk_gb: Decimal.new("0.0002")
      }

  Defaults are placeholders (see `@default_rates`) — set real rates in config.

  Payout formula, summed over a VPS's usage records in the window:

      amount = Σ (seconds / 3600) *
                 ( vcpu          * rate.vcpu
                 + (ram_mb / 1024) * rate.ram_gb
                 + disk_gb       * rate.disk_gb )
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias ControlPlane.Repo
  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.{Node, Vps}

  @seconds_per_hour Decimal.new(3600)
  @mb_per_gb Decimal.new(1024)

  # Placeholder rates. These are NOT a business price — override in config
  # (`config :control_plane, :billing_rates, %{...}`). Kept tiny and explicit so
  # an un-configured environment meters at a documented, near-zero rate rather
  # than crashing.
  @default_rates %{
    vcpu: Decimal.new("0"),
    ram_gb: Decimal.new("0"),
    disk_gb: Decimal.new("0")
  }

  @doc """
  Returns the configured resource-hour rates as a map of `Decimal`s with keys
  `:vcpu`, `:ram_gb`, `:disk_gb`. See the moduledoc for units.

  Any individual rate missing from config falls back to its `@default_rates`
  value, and integer/string/float rate values are coerced to `Decimal`.
  """
  def resource_hour_rates do
    configured = Application.get_env(:control_plane, :billing_rates, %{})

    @default_rates
    |> Map.merge(Map.take(configured, [:vcpu, :ram_gb, :disk_gb]))
    |> Map.new(fn {k, v} -> {k, to_decimal(v)} end)
  end

  @doc """
  Meters every `:active` VPS that is placed on a node, recording one
  `UsageRecord` per VPS for the time elapsed since it was last metered and
  advancing each VPS's `last_metered_at` watermark to `now`.

  For each such VPS, `seconds = now - (last_metered_at || inserted_at)`, clamped
  to be `>= 0` (a clock skew or a future watermark never produces negative
  usage). VPSes whose node has no `owner_email` are skipped (there is no operator
  to pay), and are left un-metered so they can be picked up once an owner is set.

  All inserts and watermark updates run inside a single transaction. Accepts an
  optional `now` (default `DateTime.utc_now()`) for deterministic testing.

  Returns the number of VPSes metered.
  """
  def meter_active_vpses(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    # Join to the node so we can read the operator's owner_email; only active,
    # placed VPSes on a node that actually has an operator are billable.
    meterable =
      Repo.all(
        from v in Vps,
          join: n in Node,
          on: n.id == v.node_id,
          where: v.status == :active and not is_nil(v.node_id) and not is_nil(n.owner_email),
          select: {v, n.owner_email}
      )

    {:ok, metered} =
      Repo.transaction(fn ->
        Enum.reduce(meterable, 0, fn {vps, owner_email}, count ->
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

          # Advance the watermark. We update by primary key rather than via the
          # loaded struct's changeset to keep this a cheap, targeted write.
          Repo.update_all(
            from(v in Vps, where: v.id == ^vps.id),
            set: [last_metered_at: now, updated_at: now]
          )

          count + 1
        end)
      end)

    metered
  end

  @doc """
  Aggregates raw resource-usage for an operator over the half-open-ish window
  `{from, to}` (records with `metered_at >= from and metered_at <= to`).

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
            u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at <= ^to,
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
  Computes the total payout owed to `owner_email` for usage in `{from, to}`.

  Returns a `Decimal` in the same money unit as the configured rates (see the
  moduledoc). The amount is the sum over the operator's usage records of:

      (seconds / 3600) *
        ( vcpu * rate.vcpu
        + (ram_mb / 1024) * rate.ram_gb
        + disk_gb * rate.disk_gb )
  """
  def compute_payout(owner_email, {from, to}) do
    rates = resource_hour_rates()

    Repo.all(
      from u in UsageRecord,
        where:
          u.owner_email == ^owner_email and u.metered_at >= ^from and u.metered_at <= ^to,
        select: {u.seconds, u.vcpu, u.ram_mb, u.disk_gb}
    )
    |> Enum.reduce(Decimal.new(0), fn record, acc ->
      Decimal.add(acc, record_amount(record, rates))
    end)
  end

  @doc """
  Returns a per-operator payout summary for the window `{from, to}`.

  Lists one entry per operator that has any usage in the window:

      [%{owner_email: ..., amount: %Decimal{}, seconds: integer, records: integer}, ...]

  `amount` is a `Decimal` in the configured money unit (see the moduledoc),
  ordered by descending amount then operator email for stable output.
  """
  def payout_summary({from, to}) do
    rates = resource_hour_rates()

    # Pull every billable record in the window once and fold per operator in
    # Elixir; this keeps the Decimal money math identical to compute_payout/2
    # (DB-side Decimal arithmetic across drivers is comparatively fiddly).
    Repo.all(
      from u in UsageRecord,
        where: u.metered_at >= ^from and u.metered_at <= ^to,
        select: {u.owner_email, u.seconds, u.vcpu, u.ram_mb, u.disk_gb}
    )
    |> Enum.group_by(fn {owner_email, _s, _v, _r, _d} -> owner_email end)
    |> Enum.map(fn {owner_email, records} ->
      {amount, seconds} =
        Enum.reduce(records, {Decimal.new(0), 0}, fn {_owner, s, v, r, d} = _row, {amt, secs} ->
          {Decimal.add(amt, record_amount({s, v, r, d}, rates)), secs + s}
        end)

      %{owner_email: owner_email, amount: amount, seconds: seconds, records: length(records)}
    end)
    |> Enum.sort(&payout_order/2)
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

  # Per-record payout: (seconds/3600) * (vcpu*rate.vcpu + (ram_mb/1024)*rate.ram_gb
  # + disk_gb*rate.disk_gb). All in Decimal to avoid float rounding on money.
  defp record_amount({seconds, vcpu, ram_mb, disk_gb}, rates) do
    hours = Decimal.div(Decimal.new(seconds), @seconds_per_hour)
    ram_gb = Decimal.div(Decimal.new(ram_mb), @mb_per_gb)

    per_hour =
      Decimal.new(vcpu)
      |> Decimal.mult(rates.vcpu)
      |> Decimal.add(Decimal.mult(ram_gb, rates.ram_gb))
      |> Decimal.add(Decimal.mult(Decimal.new(disk_gb), rates.disk_gb))

    Decimal.mult(hours, per_hour)
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

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
