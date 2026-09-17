defmodule ControlPlaneWeb.VpsController do
  @moduledoc """
  End-user VPS API: a registered user manages only the VPSes they own.

  Authenticated by `ControlPlaneWeb.Plugs.ApiAuth`, so `conn.assigns.current_user`
  is always present. Ownership is enforced on every read and on delete by scoping
  queries to `current_user.id`; a VPS belonging to someone else is indistinguishable
  from one that does not exist (404), never leaking its existence.

  `create` provisions on behalf of the current user (stamping `owner_id` and
  `owner_email` server-side — never from the request body) and accepts either a
  `region_id` or a human `region_code`.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.ApiResponse

  alias ControlPlane.Backups
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning

  def index(conn, _params) do
    vpses =
      conn.assigns.current_user.id
      |> Fleet.list_vpses_for_owner()
      |> Enum.map(&vps_json/1)

    json(conn, %{vpses: vpses})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id) do
      json(conn, %{vps: vps_json(vps)})
    else
      _ -> not_found(conn)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = build_attrs(params)

    with :ok <- validate_provision_input(attrs),
         :ok <- immediate_delivery_consent(params),
         {:ok, region_id} <- resolve_region_id(params, attrs),
         attrs = Map.put(attrs, :region_id, region_id),
         %Package{} = pkg <- Fleet.package_for_specs(attrs.vcpu, attrs.ram_mb, attrs.disk_gb),
         price = package_price_cents(pkg),
         {:ok, charge} <- Credits.charge(user.id, price, "vps_charge", "VPS #{pkg.name}"),
         {:ok, %{vps: vps}} <-
           charge_safe_create(
             user,
             attrs |> Map.put(:package_id, pkg.id) |> Map.put(:withdrawal_waiver_at, Clock.now()),
             price
           ),
         # The charge had to come first — the wallet is checked and debited before
         # anything is provisioned — so only now can it be told which machine it
         # paid for. Until this lands the entry is an orphan, which is exactly
         # what Credits.refund_orphan_charges/1 looks for.
         {:ok, _} <- Credits.attach_vps(charge, vps.id) do
      conn
      |> put_status(:created)
      # Re-read rather than render the struct the transaction returned: that one
      # has no node or port forwards loaded, so create would answer with a null
      # endpoint for a VPS that has one, and disagree with show/index about the
      # same machine.
      |> json(%{vps: vps_json(Fleet.get_vps_for_owner(user.id, vps.id) || vps)})
    else
      nil -> error(conn, :unprocessable_entity, "no_matching_package")
      {:error, :input_too_large} -> error(conn, :unprocessable_entity, "input_too_large")
      {:error, :no_delivery_consent} -> error(conn, :unprocessable_entity, "no_delivery_consent")
      {:error, :region_not_found} -> error(conn, :unprocessable_entity, "region_not_found")
      {:error, :insufficient_credits} -> error(conn, :payment_required, "insufficient_credits")
      {:error, :quota_exceeded} -> error(conn, :too_many_requests, "quota_exceeded")
      {:error, :no_capacity} -> error(conn, :conflict, "no_capacity")
      {:error, _reason} -> error(conn, :unprocessable_entity, "invalid_vps")
    end
  end

  # Provision after the wallet was charged; refund if provisioning fails so a
  # failed create never leaves the customer debited.
  defp charge_safe_create(user, attrs, price_cents) do
    case Provisioning.create_vps_for_owner(user, attrs) do
      {:ok, _} = ok ->
        ok

      other ->
        refund_charge(user.id, price_cents)
        other
    end
  rescue
    # A raise after the wallet was debited (bug, changeset explosion, etc.) must
    # still refund, otherwise the customer is charged for a VPS they never got.
    e ->
      refund_charge(user.id, price_cents)
      reraise e, __STACKTRACE__
  catch
    # DBConnection pool timeouts surface as an :exit, not a rescue-able error.
    :exit, reason ->
      refund_charge(user.id, price_cents)
      exit(reason)
  end

  defp refund_charge(user_id, price_cents) do
    Credits.refund(user_id, price_cents, "vps_refund", "Terugbetaling: VPS-aanmaak mislukt")
  end

  defp package_price_cents(%Package{price_monthly: price}) do
    ControlPlane.Money.to_cents(price)
  end

  def delete(conn, %{"id" => id}) do
    # Authorize first: only an owned VPS may be deleted. An unknown id, a bad id, or
    # someone else's VPS all collapse to 404 so ownership isn't leaked.
    with {:ok, id} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id),
         {:ok, %{vps: vps}} <- Provisioning.delete_vps(id) do
      conn
      |> put_status(:accepted)
      |> json(%{vps: vps_json(vps)})
    else
      {:error, :already_deleting} -> error(conn, :conflict, "already_deleting")
      {:error, :no_node} -> error(conn, :unprocessable_entity, "no_node")
      _ -> not_found(conn)
    end
  end

  @doc """
  A VPS's restore points, newest first.

  Failures are listed too. "The last three nightly backups failed" is the single
  most useful thing this endpoint can say, and it can only say it if failures
  appear.
  """
  def backups(conn, %{"id" => id}) do
    with {:ok, uuid} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid) do
      json(conn, %{backups: Enum.map(Backups.list_for_vps(uuid), &backup_json/1)})
    else
      _ -> not_found(conn)
    end
  end

  defp backup_json(%VpsBackup{} = backup) do
    %{
      id: backup.id,
      status: backup.status,
      size_bytes: backup.size_bytes,
      started_at: backup.started_at,
      finished_at: backup.finished_at,
      # Deliberately not the volid: it is the node's internal handle on a file,
      # of no use to a customer and no business of theirs.
      error: if(backup.status == :failed, do: backup.error)
    }
  end

  @doc """
  Start nu een back-up van een eigen VPS, buiten het nachtelijke schema om.

  Het moment vóór iets engs -- een upgrade, een configuratie die je zelf niet
  vertrouwt -- is precies wanneer je er een wilt, en dan is "vannacht" geen
  antwoord.
  """
  def backup_now(conn, %{"id" => id}) do
    with {:ok, uuid} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid),
         {:ok, backup} <- Backups.start_on_demand(vps) do
      conn |> put_status(:accepted) |> json(%{backup: backup_json(backup)})
    else
      {:error, :already_running} -> error(conn, :conflict, "backup_already_running")
      {:error, :node_unreachable} -> error(conn, :conflict, "node_unreachable")
      {:error, :not_provisioned} -> error(conn, :conflict, "not_provisioned")
      _ -> not_found(conn)
    end
  end

  @doc """
  Rolls an owned VPS back to one of its own restore points.

  Destructive: everything written since that backup is gone. The VPS goes to
  `:restoring` until the node reports back, which blocks every other action on it
  — including a second restore over the same disk.
  """
  def restore(conn, %{"id" => id, "backup_id" => backup_id}) do
    with {:ok, uuid} <- valid_id(id),
         {:ok, backup_uuid} <- valid_id(backup_id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid),
         {:ok, restoring} <- Backups.restore(vps, backup_uuid) do
      conn |> put_status(:accepted) |> json(%{vps: vps_json(restoring)})
    else
      {:error, {:invalid_status, status}} -> error(conn, :conflict, "invalid_status_#{status}")
      {:error, :backup_not_restorable} -> error(conn, :conflict, "backup_not_restorable")
      {:error, :not_provisioned} -> error(conn, :conflict, "not_provisioned")
      _ -> not_found(conn)
    end
  end

  @doc "Starts an owned, stopped VPS. 404 if not owned (existence is never leaked)."
  def start(conn, params), do: power(conn, params, &Provisioning.start_vps/1)

  @doc "Stops an owned, running VPS. 404 if not owned."
  def stop(conn, params), do: power(conn, params, &Provisioning.stop_vps/1)

  @doc """
  Herstart een eigen, draaiende VPS. 404 als hij niet van jou is.

  Van binnenuit: het besturingssysteem wordt gevraagd af te sluiten en komt weer
  op. Wie de stekker eruit wil trekken doet stop en daarna start -- dat is een
  andere handeling en hoort er ook als een andere handeling uit te zien.
  """
  def reboot(conn, params), do: power(conn, params, &Provisioning.reboot_vps/1)

  defp power(conn, %{"id" => id}, transition) do
    with {:ok, id} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id),
         {:ok, _} <- transition.(id) do
      json(conn, %{detail: "ok"})
    else
      {:error, {:invalid_status, status}} -> error(conn, :conflict, "invalid_status_#{status}")
      {:error, reason} -> error(conn, :unprocessable_entity, to_string(reason))
      _ -> not_found(conn)
    end
  end

  # --- helpers --------------------------------------------------------------

  # Ownership is deliberately omitted here: `Provisioning.create_vps_for_owner/2`
  # stamps `owner_id`/`owner_email` from the authenticated session and drops any
  # owner fields a caller might try to smuggle in, so spoofing is impossible.
  # Bound caller-supplied provision input so a request can't carry an absurd
  # number/size of SSH keys or a giant cloud-init blob (targets the user's own VM,
  # but unbounded input is unbounded work). Limits are generous for real use.
  # Een consument heeft veertien dagen bedenktijd. Die vervalt alleen als hij
  # uitdrukkelijk om onmiddellijke levering vraagt en erkent daarmee zijn
  # herroepingsrecht te verliezen (art. 6:230p sub f BW). Een VPS staat binnen
  # twee minuten te draaien, dus zonder die bevestiging zouden we veertien dagen
  # lang een dienst leveren die de klant nog kosteloos kan terugdraaien.
  #
  # Weigeren gebeurt hier, vóór Credits.charge: anders is de klant al gedebiteerd
  # voor een bestelling die we alsnog afwijzen.
  defp immediate_delivery_consent(params) do
    case params["immediate_delivery_consent"] do
      true -> :ok
      "true" -> :ok
      _ -> {:error, :no_delivery_consent}
    end
  end

  defp validate_provision_input(%{
         vcpu: vcpu,
         ram_mb: ram_mb,
         disk_gb: disk_gb,
         ssh_keys: ssh,
         cloud_init: ci
       }) do
    with :ok <- valid_spec(vcpu, ram_mb, disk_gb), do: bounded_input(ssh, ci)
  end

  # Reject an out-of-bounds spec up front (matches Vps.validate_spec) so an
  # invalid request fails with a clear `invalid_vps` rather than slipping through
  # to package pricing and surfacing as `no_matching_package`.
  defp valid_spec(vcpu, ram_mb, disk_gb) do
    if valid_spec_field?(vcpu, 64) and valid_spec_field?(ram_mb, 262_144) and
         valid_spec_field?(disk_gb, 8_192),
       do: :ok,
       else: {:error, :invalid_spec}
  end

  defp bounded_input(ssh, cloud_init) do
    cond do
      not is_list(ssh) -> {:error, :input_too_large}
      length(ssh) > 20 -> {:error, :input_too_large}
      Enum.any?(ssh, &oversized_key?/1) -> {:error, :input_too_large}
      encoded_size(cloud_init) > 16_384 -> {:error, :input_too_large}
      true -> :ok
    end
  end

  defp oversized_key?(key), do: not is_binary(key) or byte_size(key) > 4096

  defp valid_spec_field?(v, max) when is_integer(v), do: v > 0 and v <= max
  defp valid_spec_field?(_v, _max), do: false

  defp encoded_size(term) do
    case Jason.encode(term) do
      {:ok, json} -> byte_size(json)
      _ -> 1_000_000
    end
  end

  # Region is added after this: choosing it automatically needs the spec, so the
  # spec has to be built (and validated) first.
  defp build_attrs(params) do
    %{
      name: params["name"],
      vcpu: params["vcpu"],
      ram_mb: params["ram_mb"],
      disk_gb: params["disk_gb"],
      template_id: default_template_id(),
      ssh_keys: params["ssh_keys"] || [],
      cloud_init: allowed_cloud_init(params["cloud_init"])
      # SECURITY: never accept ip_config/ip_address from the self-service body. It
      # is a staff-only override (admin controller sets it); letting a customer set
      # it bypasses IpPool.allocate — they could pin a co-tenant's or the gateway's
      # IP (conflict/MITM) and, because ip_address stays nil, slip past the
      # vpses_active_node_ip_uidx uniqueness backstop. Force allocation via the pool.
    }
  end

  # An allow-list, not a size cap. The agent reads exactly two cloud-init keys;
  # everything else was stored in the command payload forever and then ignored,
  # which is retention without a purpose. Anything not named here is dropped.
  @cloud_init_keys ~w(user password)
  @max_cloud_init_value 128

  defp allowed_cloud_init(%{} = cloud_init) do
    cloud_init
    |> Map.take(@cloud_init_keys)
    |> Map.filter(fn {_key, value} ->
      is_binary(value) and value != "" and byte_size(value) <= @max_cloud_init_value
    end)
  end

  defp allowed_cloud_init(_), do: %{}

  defp resolve_region_id(%{"region_id" => region_id}, _attrs) when is_binary(region_id) do
    case valid_id(region_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :region_not_found}
    end
  end

  defp resolve_region_id(%{"region_code" => region_code}, _attrs) when is_binary(region_code) do
    case Fleet.region_by_code(region_code) do
      %Region{id: id} -> {:ok, id}
      nil -> {:error, :region_not_found}
    end
  end

  # No preference: Bunk picks. A named region that does not exist is still an
  # error — only the *absence* of one means "anywhere", so a typo'd region code
  # cannot quietly land a customer on the other side of the country.
  defp resolve_region_id(_params, attrs), do: Fleet.auto_region_id(attrs)

  defp valid_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp valid_id(_), do: :error

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  defp vps_json(%Vps{} = vps) do
    %{
      id: vps.id,
      name: vps.name,
      status: vps.status,
      region: region_code(vps),
      provider_vm_id: vps.provider_vm_id,
      ip_address: vps.ip_address,
      vcpu: vps.vcpu,
      ram_mb: vps.ram_mb,
      disk_gb: vps.disk_gb,
      inserted_at: vps.inserted_at,
      # Where a customer connects. Null when the node this VPS landed on has no
      # public address yet: the honest answer, and the one the UI needs in order
      # to say "console only" instead of printing an address that goes nowhere.
      public_host: public_host(vps),
      ssh_port: ssh_port(vps),
      port_forwards: port_forwards_json(vps)
    }
  end

  defp public_host(%Vps{node: %Node{public_host: host}}), do: host
  defp public_host(%Vps{}), do: nil

  defp ssh_port(%Vps{port_forwards: forwards}) when is_list(forwards) do
    Enum.find_value(forwards, fn f -> if f.target_port == 22, do: f.public_port end)
  end

  defp ssh_port(%Vps{}), do: nil

  defp port_forwards_json(%Vps{port_forwards: forwards}) when is_list(forwards) do
    Enum.map(forwards, fn f ->
      %{
        public_port: f.public_port,
        target_port: f.target_port,
        protocol: f.protocol,
        purpose: f.purpose
      }
    end)
  end

  defp port_forwards_json(%Vps{}), do: []

  defp region_code(%Vps{region: %{code: code}}), do: code
  defp region_code(%Vps{}), do: nil

  defp not_found(conn), do: error(conn, :not_found, "not_found")
end
