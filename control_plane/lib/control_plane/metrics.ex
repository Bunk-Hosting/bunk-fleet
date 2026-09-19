defmodule ControlPlane.Metrics do
  @moduledoc """
  What the platform is doing, counted rather than recorded.

  An operator needs to know whether last night brought four hundred failed
  logins, whether provisions are failing, and how much of the fleet is spoken
  for. None of those questions need to know *who*, so nothing here stores a user,
  an address or a per-attempt row — only totals per day, which carry no personal
  data at all. That is a deliberate ceiling: an admin panel that could answer
  "when did this customer last log in" is an admin panel that has to justify
  itself under the AVG, and this one never will.

  Counters are incremented with an upsert on the day, so a concurrent login and
  registration cannot lose each other's increment.
  """
  import Ecto.Query

  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @counters [:successes, :failures, :registrations, :captcha_refusals, :hibp_skipped]

  @doc """
  Adds one to `counter` for today. Unknown counters raise rather than silently
  count nothing — a typo here would be a metric that reads zero forever.
  """
  def count(counter) when counter in @counters do
    today = Date.utc_today()

    Repo.insert_all(
      "auth_daily_stats",
      [Keyword.put([day: today], counter, 1)],
      on_conflict: from(s in "auth_daily_stats", update: [inc: ^[{counter, 1}]]),
      conflict_target: :day
    )

    :ok
  end

  @doc """
  The last `days` of authentication totals, newest first.
  """
  def auth_history(days \\ 14) do
    since = Date.add(Date.utc_today(), -days)

    Repo.all(
      from s in "auth_daily_stats",
        where: s.day >= ^since,
        order_by: [desc: s.day],
        select: %{
          day: s.day,
          successes: s.successes,
          failures: s.failures,
          registrations: s.registrations,
          captcha_refusals: s.captcha_refusals,
          # Hoe vaak de controle op gelekte wachtwoorden die dag is overgeslagen
          # omdat de dienst niet bereikbaar was. Staat hier een rij getallen die
          # niet nul zijn, dan is de controle in de praktijk uit.
          hibp_skipped: s.hibp_skipped
        }
    )
  end

  @doc """
  Per-node capacity: what the fleet has, what is spoken for, and how much of the
  binding resource is left.

  RAM is the binding resource in practice — a node runs out of it long before it
  runs out of cores or disk — so `headroom_pct` is about RAM and says so.
  """
  def node_capacity do
    vps_counts =
      Repo.all(
        from v in Vps,
          where: v.status not in [:deleted, :failed],
          group_by: v.node_id,
          select: {v.node_id, count(v.id)}
      )
      |> Map.new()

    Repo.all(from n in Node, order_by: [asc: n.name])
    |> Enum.map(fn node ->
      %{
        name: node.name,
        status: node.status,
        last_heartbeat_at: node.last_heartbeat_at,
        seconds_since_heartbeat: seconds_since(node.last_heartbeat_at),
        vps_count: Map.get(vps_counts, node.id, 0),
        total_vcpu: node.total_vcpu,
        available_vcpu: node.available_vcpu,
        total_ram_mb: node.total_ram_mb,
        available_ram_mb: node.available_ram_mb,
        total_disk_gb: node.total_disk_gb,
        available_disk_gb: node.available_disk_gb,
        headroom_pct: pct(node.available_ram_mb, node.total_ram_mb)
      }
    end)
  end

  @doc """
  Dispatched work over the last `hours`, by kind and outcome.

  This is the honest health signal for the fleet: provisions that fail, teardowns
  that keep being retried, and backups that never finish all show up here before
  a customer notices.
  """
  def command_outcomes(hours \\ 24) do
    since = Clock.shift(-hours * 3600)

    Repo.all(
      from c in Command,
        where: c.inserted_at >= ^since,
        group_by: [c.kind, c.status],
        order_by: [asc: c.kind],
        select: %{kind: c.kind, status: c.status, count: count(c.id)}
    )
  end

  @doc """
  Backup health per VPS: how long ago the last one succeeded, and how many failed
  in the window.

  A backup that silently stopped running looks exactly like one that never had to
  run, which is why the age of the newest success is the number that matters
  rather than a count of rows.
  """
  def backup_health(days \\ 7) do
    since = Clock.shift(-days * 86_400)

    newest =
      Repo.all(
        from b in VpsBackup,
          where: b.status == :done,
          group_by: b.vps_id,
          select: {b.vps_id, max(b.finished_at)}
      )
      |> Map.new()

    failures =
      Repo.all(
        from b in VpsBackup,
          where: b.status == :failed and b.inserted_at >= ^since,
          group_by: b.vps_id,
          select: {b.vps_id, count(b.id)}
      )
      |> Map.new()

    Repo.all(
      from v in Vps,
        where: v.status not in [:deleted, :failed],
        order_by: [asc: v.name],
        select: %{id: v.id, name: v.name}
    )
    |> Enum.map(fn vps ->
      last = Map.get(newest, vps.id)

      %{
        name: vps.name,
        last_success_at: last,
        hours_since_success: hours_since(last),
        failures: Map.get(failures, vps.id, 0)
      }
    end)
  end

  defp seconds_since(nil), do: nil
  defp seconds_since(at), do: DateTime.diff(Clock.now(), at)

  defp hours_since(nil), do: nil
  defp hours_since(at), do: div(DateTime.diff(Clock.now(), at), 3600)

  defp pct(_part, total) when is_nil(total) or total == 0, do: nil
  defp pct(part, total), do: round(part * 100 / total)
end
