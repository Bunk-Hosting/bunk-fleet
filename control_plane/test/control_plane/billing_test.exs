defmodule ControlPlane.BillingTest do
  use ControlPlane.DataCase, async: true

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
      node = insert_node(region, "operator@example.com")
      # Last metered one hour (3600s) before @now.
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      assert [record] = usage_records_for(vps.id)
      assert record.owner_email == "operator@example.com"
      assert record.node_id == node.id
      assert record.seconds == 3600
      assert record.vcpu == vps.vcpu
      assert record.ram_mb == vps.ram_mb
      assert record.disk_gb == vps.disk_gb
      assert DateTime.compare(record.metered_at, @now) == :eq
    end

    test "advances the vps last_metered_at to now" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
      last = DateTime.add(@now, -120, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      assert DateTime.compare(Repo.get!(Vps, vps.id).last_metered_at, @now) == :eq
    end

    test "falls back to inserted_at when last_metered_at is nil" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
      # Never metered; created 600s before @now.
      created = DateTime.add(@now, -600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: nil, inserted_at: created)

      assert Billing.meter_active_vpses(@now) == 1
      assert [record] = usage_records_for(vps.id)
      assert record.seconds == 600
    end

    test "clamps negative elapsed (future watermark) to zero seconds" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
      future = DateTime.add(@now, 300, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: future)

      assert Billing.meter_active_vpses(@now) == 1
      assert [record] = usage_records_for(vps.id)
      assert record.seconds == 0
    end

    test "skips non-active vpses" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
      last = DateTime.add(@now, -3600, :second)

      for status <- [:queued, :provisioning, :failed, :deleting, :deleted] do
        insert_vps(region, node, status: status, last_metered_at: last)
      end

      assert Billing.meter_active_vpses(@now) == 0
      assert Repo.aggregate(UsageRecord, :count) == 0
    end

    test "skips active vpses whose node has no owner_email" do
      region = insert_region()
      node = insert_node(region, nil)
      last = DateTime.add(@now, -3600, :second)
      vps = insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 0
      assert usage_records_for(vps.id) == []
      # Left un-metered so it can be picked up once an owner is set.
      assert Repo.get!(Vps, vps.id).last_metered_at == last
    end

    test "skips active vpses without a node" do
      region = insert_region()
      vps = insert_vps(region, nil, status: :active, last_metered_at: nil)

      assert Billing.meter_active_vpses(@now) == 0
      assert usage_records_for(vps.id) == []
    end
  end

  describe "compute_payout/2" do
    test "computes the payout for a known usage window and rate" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
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
      # 1 hour * (2*0.010 + 2*0.004 + 20*0.0002)
      #        = 0.020 + 0.008 + 0.004 = 0.032
      window = {DateTime.add(@now, -1, :second), DateTime.add(@now, 1, :second)}
      amount = Billing.compute_payout("operator@example.com", window)

      assert Decimal.equal?(amount, Decimal.new("0.032"))
    end

    test "is zero for an operator with no usage in the window" do
      window = {DateTime.add(@now, -3600, :second), @now}
      assert Decimal.equal?(Billing.compute_payout("nobody@example.com", window), Decimal.new(0))
    end

    test "excludes records outside the window" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
      last = DateTime.add(@now, -3600, :second)
      insert_vps(region, node, status: :active, last_metered_at: last)

      assert Billing.meter_active_vpses(@now) == 1

      # Window entirely before the metered_at (@now): no records counted.
      window = {DateTime.add(@now, -7200, :second), DateTime.add(@now, -10, :second)}
      assert Decimal.equal?(Billing.compute_payout("operator@example.com", window), Decimal.new(0))
    end
  end

  describe "payout_summary/1" do
    test "groups payouts by operator" do
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
      summary = Billing.payout_summary(window)

      assert length(summary) == 2

      alice = Enum.find(summary, &(&1.owner_email == "alice@example.com"))
      bob = Enum.find(summary, &(&1.owner_email == "bob@example.com"))

      # Per-VPS hourly amount = 0.032 (see compute_payout test).
      assert Decimal.equal?(alice.amount, Decimal.new("0.064"))
      assert Decimal.equal?(bob.amount, Decimal.new("0.032"))
      assert alice.records == 2
      assert bob.records == 1
      assert alice.seconds == 7200
      assert bob.seconds == 3600
    end

    test "is empty when there is no usage in the window" do
      window = {DateTime.add(@now, -3600, :second), @now}
      assert Billing.payout_summary(window) == []
    end
  end

  describe "usage_for_owner/2" do
    test "aggregates raw resource-seconds for an operator" do
      region = insert_region()
      node = insert_node(region, "operator@example.com")
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
      usage = Billing.usage_for_owner("operator@example.com", window)

      assert usage.records == 1
      assert usage.seconds == 3600
      assert usage.vcpu_seconds == 3600 * 2
      assert usage.ram_mb_seconds == 3600 * 2048
      assert usage.disk_gb_seconds == 3600 * 20
    end
  end
end
