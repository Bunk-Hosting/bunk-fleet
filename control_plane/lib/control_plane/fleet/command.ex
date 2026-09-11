defmodule ControlPlane.Fleet.Command do
  @moduledoc """
  A unit of work dispatched to a node's agent (e.g. provision or delete a VPS).

  Commands are created server-side in the `:pending` state, picked up by the
  node's agent when it polls `GET /v1/commands` (transitioning to `:delivered`),
  and resolved to `:done` / `:failed` when the agent reports a result via
  `POST /v1/commands/:id/result`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.{Node, Vps}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "commands" do
    field :kind, Ecto.Enum,
      values: [
        :provision,
        :delete,
        :start,
        :stop,
        :pause,
        :resume,
        # Disk backups. Unlike the verbs above these change nothing about the
        # VPS itself — they act on archives beside it — so they finalise into
        # `vps_backups` rather than into the VPS's status.
        :backup,
        :delete_backup,
        # Rolling a guest back to an archive. Unlike the other two this DOES
        # change the VPS — it overwrites its disk — so it finalises into the
        # VPS's status as well as the backup row.
        :restore_backup
      ]

    field :payload, :map, default: %{}

    field :status, Ecto.Enum,
      values: [:pending, :delivered, :done, :failed],
      default: :pending

    field :result, :map

    # Stamped on each (re)delivery; nil until first delivered. Drives redelivery
    # of commands whose agent crashed before reporting a result.
    field :delivered_at, :utc_datetime

    belongs_to :node, Node
    belongs_to :vps, Vps

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(command, attrs) do
    command
    |> cast(attrs, [:node_id, :vps_id, :kind, :payload, :status, :result, :delivered_at])
    |> validate_required([:node_id, :kind])
    |> assoc_constraint(:node)
    |> assoc_constraint(:vps)
  end
end
