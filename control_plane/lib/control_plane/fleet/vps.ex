defmodule ControlPlane.Fleet.Vps do
  @moduledoc """
  A virtual private server requested by a customer, placed onto a node within a
  region.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vpses" do
    field :name, :string

    field :status, Ecto.Enum,
      values: [
        :queued,
        :provisioning,
        :active,
        :stopped,
        :paused,
        # Being rolled back to a backup. A state of its own rather than reusing
        # :provisioning, because the disk is being overwritten with older data
        # and every other action on this VPS has to wait — including a second
        # restore, which would race the first over the same disk.
        :restoring,
        :failed,
        :deleting,
        :deleted
      ],
      default: :queued

    # Requested spec.
    field :vcpu, :integer
    field :ram_mb, :integer
    field :disk_gb, :integer

    # The authenticated account that owns this VPS (nil for admin-/system-created
    # VPSes). `owner_email` is a free-text label kept for admin-created rows and
    # display; `owner_id` is the authoritative ownership link for authorization.
    field :owner_email, :string
    belongs_to :user, User, foreign_key: :owner_id

    # Provider-side identity, populated once the node's agent reports a successful
    # provision result.
    field :provider_vm_id, :string
    field :ip_address, :string
    field :package_id, :integer

    # TOFU-pinned SSH host-key fingerprint (SHA256:...), recorded on the first
    # browser-console connection and verified on every later one to detect a
    # hypervisor-operator MITM of the console (see Console.HostKeys, O-33).
    field :ssh_host_key, :string

    # Accrual-metering watermark: the timestamp through which this VPS has
    # already been metered into `usage_records` (see `ControlPlane.Billing`).
    field :last_metered_at, :utc_datetime

    belongs_to :region, Region
    belongs_to :node, Node
    has_many :port_forwards, ControlPlane.Fleet.PortForward

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(vps, attrs) do
    vps
    |> cast(attrs, [
      :name,
      :region_id,
      :node_id,
      :status,
      :vcpu,
      :ram_mb,
      :disk_gb,
      :owner_email,
      :owner_id,
      :provider_vm_id,
      :ip_address,
      :package_id,
      :last_metered_at
    ])
    |> validate_required([:name, :region_id, :vcpu, :ram_mb, :disk_gb])
    |> validate_length(:name, max: 100)
    # Reject control characters (newlines, etc.) so a name can't break out of the
    # cloud-init/guestinfo YAML the agent renders for the VM (injection hardening).
    |> validate_format(:name, ~r/\A[^\x00-\x1F\x7F]*\z/,
      message: "mag geen controltekens bevatten"
    )
    |> validate_spec()
    |> assoc_constraint(:region)
    |> assoc_constraint(:node)
    |> assoc_constraint(:user)
    |> unique_constraint(:ip_address, name: :vpses_active_node_ip_uidx)
  end

  # Hard platform bounds on the requested spec. The lower bounds (> 0) are a
  # data-integrity guard: a zero/negative spec would otherwise sail through the
  # scheduler's `available_* >= requested` check and *inflate* node capacity when
  # the reservation is later restored. The upper bounds are sanity ceilings for a
  # single VPS (per-plan/quota limits live above this, in the owner flow).
  @max_vcpu 64
  @max_ram_mb 262_144
  @max_disk_gb 8_192

  defp validate_spec(changeset) do
    changeset
    |> validate_number(:vcpu, greater_than: 0, less_than_or_equal_to: @max_vcpu)
    |> validate_number(:ram_mb, greater_than: 0, less_than_or_equal_to: @max_ram_mb)
    |> validate_number(:disk_gb, greater_than: 0, less_than_or_equal_to: @max_disk_gb)
  end
end
