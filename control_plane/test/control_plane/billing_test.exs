defmodule ControlPlane.BillingTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Billing
  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.{Node, Region, Vps}

  # A fixed "now" for deterministic metering/seconds assertions.
  @now ~U[2026-06-25 12:00:00Z]

  # --- inline insert helpers -------------------------------------------------

  defp insert_region(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Region #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp insert_node(region, owner_email) do
    %Node{}
    |> Node.changeset(%{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      owner_email: owner_email
    })
    # Metering only accrues for :online, recently-heartbeating nodes, so the
    # fixture must present that state to be metered.
    |> Ecto.Changeset.put_change(:status, :online)
    |> Ecto.Changeset.put_change(
      :last_heartbeat_at,
      DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.insert!()
  end

  # Inserts a VPS with full control over status / node / metering timestamps.
  defp insert_vps(region, node, opts) do
    status = Keyword.get(opts, :status, :active)
    vcpu = Keyword.get(opts, :vcpu, 2)
    ram_mb = Keyword.get(opts, :ram_mb, 2048)
    disk_gb = Keyword.get(opts, :disk_gb, 20)
    last_metered_at = Keyword.get(opts, :last_metered_at)
    inserted_at = Keyword.get(opts, :inserted_at, @now)

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node && node.id,
      status: status,
      vcpu: vcpu,
      ram_mb: ram_mb,
      disk_gb: disk_gb,
      owner_email: "customer@example.com",
      owner_id: Keyword.get(opts, :owner_id),
      last_metered_at: last_metered_at
    })
    # status defaults to :queued via the schema; force the requested status and
    # back-date inserted_at so first-meter fallback (= inserted_at) is testable.
    |> Ecto.Changeset.put_change(:status, status)
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Repo.insert!()
  end

  defp usage_records_for(vps_id) do
    Repo.all(from u in UsageRecord, where: u.vps_id == ^vps_id)
  end

  describe "meter_active_vpses/1" do
    test "records usage for an active vps with seconds since last_metered_at" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      # Last metered one hour (3600s) before @now.
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      assert [record] = usage_records_for(vps.id)
      assert record.owner_email == "nl1-ops@bunkhosting.nl"
      assert record.node_id == node.id
      assert record.seconds == 3600
      assert record.vcpu == vps.vcpu
      assert record.ram_mb == vps.ram_mb
      assert record.disk_gb == vps.disk_gb
      assert DateTime.compare(record.metered_at, @now) == :eq
    end

    test "advances the vps last_metered_at to now" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -120, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      assert DateTime.compare(Repo.get!(Vps, vps.id).last_metered_at, @now) == :eq
    end

    test "falls back to inserted_at when last_metered_at is nil" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      # Never metered; created 600s before @now.
      created = DateTime.add(@now, -600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: nil, inserted_at: created)

      assert Billing.meter_active_vpses(@now) == 1
      assert [record] = usage_records_for(vps.id)
      assert record.seconds == 600
    end

    test "clamps negative elapsed (future watermark) to zero seconds" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      future = DateTime.add(@now, 300, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: future)

      assert Billing.meter_active_vpses(@now) == 1
      assert [record] = usage_records_for(vps.id)
      assert record.seconds == 0
    end

    test "skips non-active vpses" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)

      for status <- [:queued, :provisioning, :failed, :deleting, :deleted] do
        insert_vps(region, node, status: status, last_metered_at: last)
      end

      assert Billing.meter_active_vpses(@now) == 0
      assert Repo.aggregate(UsageRecord, :count) == 0
    end

    test "meters a node without an owner_email, attributing it to the node name" do
      region = insert_region()
      node = insert_node(region, nil)
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      # Every node is our own capacity, so none may drop out of the cost picture.
      # With no cost centre set the node's own name is the attribution key.
      assert Billing.meter_active_vpses(@now) == 1
      assert [record] = usage_records_for(vps.id)
      assert record.owner_email == node.name
    end

    test "skips active vpses without a node" do
      region = insert_region()
      vps = insert_vps(region, nil, status: :active, last_metered_at: nil)

      assert Billing.meter_active_vpses(@now) == 0
      assert usage_records_for(vps.id) == []
    end
  end

  describe "resource_cost_for_owner/2" do
    test "computes the resource cost for a known usage window and rate" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      # Meter exactly one hour of a 2 vCPU / 2048 MB (= 2 GB) / 20 GB VPS.
      last = DateTime.add(@now, -3600, :second)
      insert_vps(region, node,
        status: :active,
        last_metered_at: last,
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20
      )

      assert Billing.meter_active_vpses(@now) == 1

      # Rates (config/test.exs): vcpu 0.010, ram_gb 0.004, disk_gb 0.0002.
      # Exact numerator = 3600 * (2*0.010*1024 + 2048*0.004 + 20*0.0002*1024)
      #                 = 3600 * (20.48 + 8.192 + 4.096) = 3600 * 32.768 = 117964.8
      # amount = 117964.8 / (3600*1024) = 117964.8 / 3686400 = 0.032
      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}
      amount = Billing.resource_cost_for_owner("nl1-ops@bunkhosting.nl", window)

      assert Decimal.equal?(amount, Decimal.new("0.032"))
      # Rounded to the fixed money scale (6 dp).
      assert Decimal.to_string(amount) == "0.032000"
    end

    test "resource_cost_for_owner/2 and resource_cost_summary/1 reconcile bit-for-bit" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)

      # Awkward sizes/durations so any per-record rounding drift would surface.
      insert_vps(region, node,
        status: :active,
        last_metered_at: DateTime.add(@now, -777, :second),
        vcpu: 3,
        ram_mb: 1500,
        disk_gb: 13
      )

      insert_vps(region, node, status: :active, last_metered_at: last, vcpu: 1, ram_mb: 333, disk_gb: 7)

      assert Billing.meter_active_vpses(@now) == 2

      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}
      total = Billing.resource_cost_for_owner("nl1-ops@bunkhosting.nl", window)

      [%{amount: summary_amount}] = Billing.resource_cost_summary(window)

      # Same exact-numerator/divide-once helper, so identical to the byte.
      assert Decimal.to_string(summary_amount) == Decimal.to_string(total)
    end

    test "is zero for an operator with no usage in the window" do
      window = {DateTime.add(@now, -3600, :second), @now}
      assert Decimal.equal?(Billing.resource_cost_for_owner("nobody@example.com", window), Decimal.new(0))
    end

    test "excludes records outside the window" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)
      insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      # Window entirely before the metered_at (@now): no records counted.
      window = {DateTime.add(@now, -7200, :second), DateTime.add(@now, -10, :second)}
      assert Decimal.equal?(Billing.resource_cost_for_owner("nl1-ops@bunkhosting.nl", window), Decimal.new(0))
    end

    test "window is half-open: [from, to) includes from-boundary, excludes to-boundary" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)
      insert_vps(region, node, status: :active, last_metered_at: last)

      # One record stamped exactly at @now.
      assert Billing.meter_active_vpses(@now) == 1

      # `to == @now` must EXCLUDE the boundary record (metered_at < to).
      excl = {DateTime.add(@now, -10, :second), @now}
      assert Decimal.equal?(Billing.resource_cost_for_owner("nl1-ops@bunkhosting.nl", excl), Decimal.new(0))

      # `from == @now` must INCLUDE the boundary record (metered_at >= from).
      incl = {@now, DateTime.add(@now, 10, :second)}
      assert Decimal.equal?(Billing.resource_cost_for_owner("nl1-ops@bunkhosting.nl", incl), Decimal.new("0.032"))
    end
  end

  describe "double-bill prevention" do
    test "a second immediate meter at the same `now` is a no-op (no double-bill)" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      # Re-running at the same `now`: the VPS's watermark already equals @now, so
      # it is skipped (meters 0) rather than producing a duplicate slice. This is
      # the graceful path; the unique (vps_id, metered_at) index is the backstop
      # if a true concurrent race ever got past it.
      assert Billing.meter_active_vpses(@now) == 0

      assert [record] = usage_records_for(vps.id)
      assert record.seconds == 3600
    end

    test "advancing `now` accrues only the newly-elapsed seconds (no double-bill)" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      later = DateTime.add(@now, 1800, :second)
      assert Billing.meter_active_vpses(later) == 1

      seconds = usage_records_for(vps.id) |> Enum.map(& &1.seconds) |> Enum.sort()
      # 3600 from the first tick, then exactly 1800 more — not 3600+5400.
      assert seconds == [1800, 3600]
    end

    test "duplicate (vps_id, metered_at) insert is rejected by the unique index" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      vps = insert_vps(region, node, status: :active, last_metered_at: DateTime.add(@now, -60, :second))

      attrs = %{
        vps_id: vps.id,
        node_id: node.id,
        owner_email: "nl1-ops@bunkhosting.nl",
        seconds: 60,
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20,
        metered_at: @now
      }

      assert {:ok, _} = Repo.insert(UsageRecord.changeset(%UsageRecord{}, attrs))

      assert {:error, changeset} = Repo.insert(UsageRecord.changeset(%UsageRecord{}, attrs))
      refute changeset.valid?
      assert {_msg, _opts} = changeset.errors[:vps_id]
    end
  end

  describe "resource_cost_summary/1" do
    test "groups resource cost by node cost centre" do
      region = insert_region()
      node_a = insert_node(region, "alice@example.com")
      node_b = insert_node(region, "bob@example.com")
      last = DateTime.add(@now, -3600, :second)

      # Alice runs two VPSes (2 vCPU + 2 GB + 20 GB each), Bob runs one.
      insert_vps(region, node_a, status: :active, last_metered_at: last)
      insert_vps(region, node_a, status: :active, last_metered_at: last)
      insert_vps(region, node_b, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 3

      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}
      summary = Billing.resource_cost_summary(window)

      assert length(summary) == 2

      alice = Enum.find(summary, &(&1.owner_email == "alice@example.com"))
      bob = Enum.find(summary, &(&1.owner_email == "bob@example.com"))

      # Per-VPS hourly amount = 0.032 (see resource_cost_for_owner test).
      assert Decimal.equal?(alice.amount, Decimal.new("0.064"))
      assert Decimal.equal?(bob.amount, Decimal.new("0.032"))
      assert alice.records == 2
      assert bob.records == 1
      assert alice.seconds == 7200
      assert bob.seconds == 3600
    end

    test "is empty when there is no usage in the window" do
      window = {DateTime.add(@now, -3600, :second), @now}
      assert Billing.resource_cost_summary(window) == []
    end
  end

  describe "usage_for_owner/2" do
    test "aggregates raw resource-seconds for a cost centre" do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      last = DateTime.add(@now, -3600, :second)
      insert_vps(region, node,
        status: :active,
        last_metered_at: last,
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20
      )

      assert Billing.meter_active_vpses(@now) == 1

      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}
      usage = Billing.usage_for_owner("nl1-ops@bunkhosting.nl", window)

      assert usage.records == 1
      assert usage.seconds == 3600
      assert usage.vcpu_seconds == 3600 * 2
      assert usage.ram_mb_seconds == 3600 * 2048
      assert usage.disk_gb_seconds == 3600 * 20
    end
  end

  describe "customer_usage/2" do
    defp user_fixture(email) do
      {:ok, user} = Accounts.register_user(%{email: email, password: "super-secret-pw-123"})
      user
    end

    # Meters one 3600s slice for an active VPS owned by `user`.
    defp meter_one_hour(region, node, user) do
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last, owner_id: user.id)
      assert Billing.meter_active_vpses(@now) >= 1
      vps
    end

    setup do
      region = insert_region()
      node = insert_node(region, "nl1-ops@bunkhosting.nl")
      %{region: region, node: node, user: user_fixture("a@example.com"), other: user_fixture("b@example.com")}
    end

    test "charges the owner the exact cost of their own VPS", ctx do
      vps = meter_one_hour(ctx.region, ctx.node, ctx.user)
      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}

      usage = Billing.customer_usage(ctx.user.id, window)

      assert usage.total_seconds == 3600
      # 3600 * (2*0.010*1024 + 2048*0.004 + 20*0.0002*1024) / (3600*1024) = 0.032000
      assert Decimal.equal?(usage.total_cost, Decimal.new("0.032000"))
      assert [%{vps_id: id, seconds: 3600, cost: cost}] = usage.vpses
      assert id == vps.id
      assert Decimal.equal?(cost, Decimal.new("0.032000"))
    end

    test "never includes another owner's usage", ctx do
      _mine = meter_one_hour(ctx.region, ctx.node, ctx.user)
      _theirs = meter_one_hour(ctx.region, ctx.node, ctx.other)

      mine = Billing.customer_usage(ctx.user.id, {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)})
      assert length(mine.vpses) == 1
      assert mine.total_seconds == 3600
    end

    test "excludes records outside the half-open window", ctx do
      _vps = meter_one_hour(ctx.region, ctx.node, ctx.user)
      # Window strictly before the metered slice at @now.
      past = {DateTime.add(@now, -10, :second), DateTime.add(@now, -5, :second)}

      usage = Billing.customer_usage(ctx.user.id, past)
      assert usage.total_seconds == 0
      assert usage.vpses == []
      assert Decimal.equal?(usage.total_cost, Decimal.new(0))
    end
  end
end
