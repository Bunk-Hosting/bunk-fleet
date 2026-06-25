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

  alias ControlPlane.Repo
  alias ControlPlane.Fleet.{EnrollToken, Node}

  @token_bytes 32

  @doc """
  Mints a new single-use enroll token for `region_id` / `tier`, valid for
  `ttl_seconds`.

  Returns `{:ok, {plaintext_token, %EnrollToken{}}}`. The plaintext token is the
  only copy ever returned — only its hash is persisted.
  """
  def create_enroll_token(%{region_id: region_id, tier: tier, ttl_seconds: ttl_seconds}) do
    plaintext = generate_token()
    expires_at = DateTime.add(now(), ttl_seconds, :second)

    result =
      %EnrollToken{}
      |> EnrollToken.changeset(%{
        token_hash: hash(plaintext),
        region_id: region_id,
        tier: tier,
        expires_at: expires_at
      })
      |> Repo.insert()

    case result do
      {:ok, enroll_token} -> {:ok, {plaintext, enroll_token}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Exchanges a valid (unused, unexpired) enroll token for a new node.

  On success creates a `Node` in the token's region and tier, marks the token used,
  and returns `{:ok, %{node: node, agent_token: plaintext}}` where `agent_token` is
  the plaintext long-lived agent token (shown once). Only its hash is stored on the
  node.

  Any malformed/used/expired/unknown token yields `{:error, :invalid_token}`.
  """
  def enroll(token_plaintext, %{hypervisor: hypervisor} = attrs)
      when is_binary(token_plaintext) do
    agent_token = generate_token()

    Repo.transaction(fn ->
      with %EnrollToken{} = token <- fetch_valid_token(token_plaintext),
           {:ok, node} <- create_node(token, hypervisor, agent_token),
           {:ok, _token} <- consume_token(token) do
        %{node: node, agent_token: agent_token}
      else
        _ -> Repo.rollback(:invalid_token)
      end
    end)
  end

  def enroll(_token_plaintext, _attrs), do: {:error, :invalid_token}

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
    now = now()

    query =
      from t in EnrollToken,
        where:
          t.token_hash == ^token_hash and
            is_nil(t.used_at) and
            (is_nil(t.expires_at) or t.expires_at >= ^now)

    Repo.one(query)
  end

  defp create_node(%EnrollToken{} = token, hypervisor, agent_token) do
    %Node{}
    |> Node.changeset(%{
      name: "node-" <> short_id(),
      region_id: token.region_id,
      tier: token.tier,
      hypervisor: hypervisor,
      status: :online,
      last_heartbeat_at: now(),
      agent_token_hash: hash(agent_token)
    })
    |> Repo.insert()
  end

  defp consume_token(%EnrollToken{} = token) do
    token
    |> EnrollToken.changeset(%{used_at: now()})
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
