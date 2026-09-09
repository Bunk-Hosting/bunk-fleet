defmodule ControlPlane.Accounts.UserToken do
  @moduledoc """
  A bearer session token tying an authenticated request back to a `User`.

  A raw 32-byte random token is generated and handed to the client once; only its
  SHA-256 hash is persisted (in the `token` column) so a database leak cannot be
  replayed. Session tokens are valid for `@session_validity_in_days` days.
  """
  use Ecto.Schema
  import Ecto.Query

  alias ControlPlane.Accounts.{User, UserToken}

  @hash_algorithm :sha256
  @rand_size 32

  @session_validity_in_days 60

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_tokens" do
    field :token, :binary
    field :context, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a session token and its (unpersisted) struct.

  Returns `{raw_token, user_token}` where `raw_token` is the value handed to the
  client and `user_token.token` is its SHA-256 hash, ready to be inserted.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {token, %UserToken{token: hashed_token, context: "session", user_id: user.id}}
  end

  @doc """
  Query that fetches the `User` associated with a non-expired session token.

  `token` is the raw token; it is hashed before lookup so it matches what is stored.
  """
  def verify_session_token_query(token) do
    hashed_token = :crypto.hash(@hash_algorithm, token)

    query =
      from token in by_token_and_context_query(hashed_token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  # Email-link tokens: "confirm" (registration) and "reset_password". Unlike
  # session tokens these are single-use — the caller deletes the row once
  # consumed (see ControlPlane.Accounts) — and URL-safe-base64 encoded (not raw
  # bytes) because they travel inside a mailto link's query string.
  @email_token_validity_seconds %{
    # 24h to confirm a fresh registration.
    "confirm" => 60 * 60 * 24,
    # 1h for a password-reset link — short-lived because a leaked link (mail
    # provider log, forwarded email, shoulder surfing) directly resets a password.
    "reset_password" => 60 * 60
  }

  @doc """
  Builds a single-use email-link token for `context` ("confirm" or
  "reset_password"). Returns `{url_safe_token, %UserToken{}}` — the raw token is
  the only copy ever handed to the caller; only its hash is persisted.
  """
  def build_email_token(%User{} = user, context) when is_map_key(@email_token_validity_seconds, context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{token: hashed_token, context: context, user_id: user.id}}
  end

  @doc """
  Query that fetches the `User` for a non-expired, single-use `context` token.

  `token` is the URL-safe-base64 string handed out by `build_email_token/2`.
  Returns `{:ok, query}` (matching zero or one row — `Repo.one/1` it) on a
  well-formed token, or `:error` if it doesn't even decode.
  """
  def verify_email_token_query(token, context)
      when is_map_key(@email_token_validity_seconds, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        validity_seconds = Map.fetch!(@email_token_validity_seconds, context)

        query =
          from t in by_token_and_context_query(hashed_token, context),
            join: user in assoc(t, :user),
            where: t.inserted_at > ago(^validity_seconds, "second"),
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Query that matches a stored (hashed) token within a given context.
  """
  def by_token_and_context_query(hashed_token, context) do
    from UserToken, where: [token: ^hashed_token, context: ^context]
  end

  @doc """
  Query for all tokens belonging to `user` in the given `contexts` (or `:all`).
  """
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
