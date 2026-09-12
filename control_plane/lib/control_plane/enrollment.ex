defmodule ControlPlane.Enrollment do
  @moduledoc """
  Worker-node onboarding: minting single-use enroll tokens and exchanging a valid
  enroll token for a freshly created `ControlPlane.Fleet.Node` plus a long-lived
  agent token.

  Token handling rules:

    * Only SHA-256 hashes of secrets are stored. Plaintext tokens (the enroll token
      and the per-node agent token) are returned exactly once, at creation time.
    * Enroll tokens are single-use and time-limited.
    * The agent token authenticates a node on every subsequent heartbeat / command
      poll; it is looked up by hash via `authenticate_node/1`.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.EnrollToken
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Subnets
  alias ControlPlane.Repo

  @token_bytes 32

  @doc """
  Mints a new single-use enroll token for `region_id`, valid for
  `ttl_seconds`.

  Returns `{:ok, {plaintext_token, %EnrollToken{}}}`. The plaintext token is the
  only copy ever returned — only its hash is persisted.
  """
  def create_enroll_token(%{region_id: region_id, ttl_seconds: ttl_seconds} = attrs) do
    plaintext = generate_token()
    expires_at = Clock.shift(ttl_seconds)

    result =
      %EnrollToken{}
      |> EnrollToken.changeset(%{
        token_hash: hash(plaintext),
        region_id: region_id,
        expires_at: expires_at,
        # Which admin minted this token (audit trail); nil for system-minted.
        owner_id: Map.get(attrs, :owner_id),
        owner_email: Map.get(attrs, :owner_email)
      })
      |> Repo.insert()

    case result do
      {:ok, enroll_token} -> {:ok, {plaintext, enroll_token}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Exchanges a valid (unused, unexpired) enroll token for a new node.

  On success creates a `Node` in the token's region, marks the token used,
  and returns `{:ok, %{node: node, agent_token: plaintext}}` where `agent_token` is
  the plaintext long-lived agent token (shown once). Only its hash is stored on the
  node.

  Any malformed/used/expired/unknown token yields `{:error, :invalid_token}`.
  """
  def enroll(token_plaintext, %{hypervisor: hypervisor} = attrs)
      when is_binary(token_plaintext) do
    agent_token = generate_token()
    net = Map.get(attrs, :vps_network, %{})

    Repo.transaction(fn ->
      with %EnrollToken{} = token <- fetch_valid_token(token_plaintext),
           {:ok, vps_network} <- resolve_vps_network(net),
           {:ok, node} <- create_node(token, hypervisor, agent_token, vps_network),
           {:ok, _token} <- consume_token(token) do
        %{node: node, agent_token: agent_token}
      else
        {:error, :supernet_exhausted} -> Repo.rollback(:supernet_exhausted)
        _ -> Repo.rollback(:invalid_token)
      end
    end)
  end

  def enroll(_token_plaintext, _attrs), do: {:error, :invalid_token}

  # The node's VPS network. An agent that declared a complete network at
  # enrollment keeps it — that is the escape hatch for an operator whose machine
  # already has a subnet it must live on. Everyone else is handed the lowest free
  # block of the fleet supernet, so two nodes can never be told to use the same
  # addresses. Runs inside the enrollment transaction, behind the advisory lock,
  # because "the lowest free block" is only true until someone else takes it.
  defp resolve_vps_network(declared) when is_map(declared) do
    fields = %{
      vps_gateway: Map.get(declared, :gateway),
      # JSON gives the prefix as a number, but an agent that sends "22" means the
      # same thing and must not be treated as "declared nothing".
      vps_cidr_prefix: normalize_prefix(Map.get(declared, :cidr_prefix)),
      vps_range_start: Map.get(declared, :range_start),
      vps_range_end: Map.get(declared, :range_end)
    }

    # All four or none. A half-declared network is a misconfigured agent, and
    # quietly handing it an auto-assigned block instead would put its VPSes on a
    # subnet its own bridge does not carry — so let Node.changeset reject it and
    # the operator see the enrollment fail.
    if Enum.any?(fields, fn {_k, v} -> not is_nil(v) end) do
      {:ok, fields}
    else
      auto_vps_network()
    end
  end

  defp resolve_vps_network(_declared), do: auto_vps_network()

  defp auto_vps_network do
    :ok = Subnets.lock(Repo)

    case Subnets.next_free_block(Repo) do
      {:ok, _index, block} -> {:ok, block}
      {:error, :supernet_exhausted} = error -> error
    end
  end

  defp normalize_prefix(prefix) when is_integer(prefix) and prefix >= 1 and prefix <= 32,
    do: prefix

  defp normalize_prefix(prefix) when is_binary(prefix) do
    case Integer.parse(prefix) do
      {n, ""} -> normalize_prefix(n)
      _ -> nil
    end
  end

  defp normalize_prefix(_), do: nil

  @doc """
  Authenticates a node by its plaintext bearer agent token.

  Returns `{:ok, node}` if a node exists whose `agent_token_hash` matches, otherwise
  `:error`.
  """
  def authenticate_node(bearer_plaintext) when is_binary(bearer_plaintext) do
    case Repo.get_by(Node, agent_token_hash: hash(bearer_plaintext)) do
      %Node{} = node -> {:ok, node}
      nil -> :error
    end
  end

  def authenticate_node(_), do: :error

  # --- internal helpers -----------------------------------------------------

  defp fetch_valid_token(token_plaintext) do
    token_hash = hash(token_plaintext)
    now = Clock.now()

    # FOR UPDATE so concurrent enrollments with the same token serialize: the
    # first locks + consumes it, the second then sees used_at set and gets nil
    # (-> :invalid_token). Without the lock both could pass the used_at check and
    # mint two nodes from one single-use token (TOCTOU).
    query =
      from t in EnrollToken,
        where:
          t.token_hash == ^token_hash and
            is_nil(t.used_at) and
            (is_nil(t.expires_at) or t.expires_at >= ^now),
        lock: "FOR UPDATE"

    Repo.one(query)
  end

  defp create_node(%EnrollToken{} = token, hypervisor, agent_token, net) do
    %Node{}
    |> Node.changeset(%{
      name: "node-" <> short_id(),
      region_id: token.region_id,
      hypervisor: hypervisor,
      status: :online,
      last_heartbeat_at: Clock.now(),
      agent_token_hash: hash(agent_token),
      # Cost-centre attribution: which person/team inside Bunk this node belongs
      # to. Optional — metering falls back to the node name when it's nil.
      owner_email: token.owner_email,
      # The node's VPS network: its own if the agent declared one, else the block
      # the control plane carved for it (see resolve_vps_network/1).
      vps_gateway: net.vps_gateway,
      vps_cidr_prefix: net.vps_cidr_prefix,
      vps_range_start: net.vps_range_start,
      vps_range_end: net.vps_range_end
    })
    |> Repo.insert()
  end

  defp consume_token(%EnrollToken{} = token) do
    token
    |> EnrollToken.changeset(%{used_at: Clock.now()})
    |> Repo.update()
  end

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp short_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
