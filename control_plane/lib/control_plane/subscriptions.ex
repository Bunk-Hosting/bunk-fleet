defmodule ControlPlane.Subscriptions do
  @moduledoc "Customer subscriptions — one per VPS, charged at the package price."
  import Ecto.Query

  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription
  alias ControlPlane.Fleet

  @doc "Creates an active subscription for a VPS from its package (idempotent on vps_id)."
  def create_for_vps(vps, owner_id, package_id) when not is_nil(package_id) do
    case Fleet.get_package(package_id) do
      nil ->
        {:error, :no_package}

      pkg ->
        today = Date.utc_today()

        %Subscription{}
        |> Subscription.changeset(%{
          vps_id: vps.id,
          owner_id: owner_id,
          package_id: pkg.id,
          price_monthly: pkg.price_monthly,
          status: :active,
          billing_cycle: :monthly,
          started_at: DateTime.truncate(DateTime.utc_now(), :second),
          next_billing_date: next_month(today)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: :vps_id)
    end
  end

  def create_for_vps(_vps, _owner_id, _package_id), do: {:ok, nil}

  def list_active(owner_id) do
    Repo.all(
      from s in Subscription,
        where: s.owner_id == ^owner_id and s.status == :active,
        order_by: [desc: s.inserted_at],
        preload: [:vps]
    )
  end

  def active_count(owner_id) do
    Repo.one(from s in Subscription, where: s.owner_id == ^owner_id and s.status == :active, select: count(s.id))
  end

  @doc "Total recurring monthly cost (sum of active subscription prices)."
  def monthly_total(owner_id) do
    Repo.one(
      from s in Subscription,
        where: s.owner_id == ^owner_id and s.status == :active,
        select: coalesce(sum(s.price_monthly), 0)
    ) || Decimal.new(0)
  end

  @doc "The earliest upcoming billing date across active subscriptions."
  def next_billing_date(owner_id) do
    Repo.one(
      from s in Subscription,
        where: s.owner_id == ^owner_id and s.status == :active and not is_nil(s.next_billing_date),
        select: min(s.next_billing_date)
    )
  end

  defp next_month(date) do
    case Date.new(date.year, date.month, 1) do
      {:ok, first} -> Date.add(first, 31) |> then(&%{&1 | day: min(date.day, Date.days_in_month(&1))})
      _ -> Date.add(date, 30)
    end
  end
end
