defmodule ControlPlane.Accounts do
  @moduledoc """
  User identity and authentication for the control-plane API.

  Handles registration (pbkdf2 password hashing), email + password login with
  constant-time comparison, and bearer session tokens. Session tokens are stored
  hashed at rest — see `ControlPlane.Accounts.UserToken` — and the raw token is
  returned to the caller exactly once at generation time.
  """
  import Ecto.Query, warn: false

  require Logger

  alias ControlPlane.Accounts.User
  alias ControlPlane.Accounts.UserToken
  alias ControlPlane.Credits
  alias ControlPlane.Notifier
  alias ControlPlane.Repo

  @doc """
  Fetches a user by id, raising `Ecto.NoResultsError` if none exists.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Looks up a user by email (citext, case-insensitive). Returns nil if none."
  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc "Looks up a user by id, or nil if not found."
  def get_user(id), do: Repo.get(User, id)

  ## TOTP multi-factor authentication

  @doc "True once the user has set up AND confirmed a TOTP authenticator."
  def totp_active?(%User{totp_confirmed_at: nil}), do: false
  def totp_active?(%User{totp_secret: secret}) when is_binary(secret), do: true
  def totp_active?(_), do: false

  @doc "Generates a fresh (unconfirmed) TOTP secret for the user and persists it."
  # Refuse to reset a VPS owner who has ALREADY confirmed 2FA: overwriting the
  # secret here would silently disable their working authenticator. Combined with
  # cookie auth + SameSite=Lax (which still attaches the cookie on a top-level GET
  # navigation), an attacker could otherwise CSRF a victim into losing 2FA. To
  # re-enrol they must first disable it, which requires a valid current code.
  def start_totp_setup(%User{totp_confirmed_at: confirmed}) when not is_nil(confirmed),
    do: {:error, :already_enabled}

  def start_totp_setup(%User{} = user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(totp_secret: NimbleTOTP.secret(), totp_confirmed_at: nil)
      |> Repo.update()

    user
  end

  @doc "Confirms TOTP setup by verifying a code against the pending secret."
  def confirm_totp(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    if valid_totp_code?(secret, code) do
      user
      |> Ecto.Changeset.change(totp_confirmed_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  def confirm_totp(_user, _code), do: {:error, :invalid_code}

  @doc "Disables TOTP (also cancels an unconfirmed setup), clearing the secret."
  def disable_totp(%User{} = user) do
    user
    |> Ecto.Changeset.change(totp_secret: nil, totp_confirmed_at: nil)
    |> Repo.update()
  end

  @doc """
  Validates a login TOTP code for an MFA-active user, single-use per time-step:
  on success the accepted step is recorded (`since:`) so the same 6-digit code
  can't be replayed within its ~30s window (a stolen-then-reused code is dead).
  """
  def valid_totp?(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    trimmed = String.trim(to_string(code))

    now = DateTime.truncate(DateTime.utc_now(), :second)

    if byte_size(trimmed) == 6 and
         NimbleTOTP.valid?(secret, trimmed, since: user.totp_last_used_at) do
      # Atomically claim this time-step so a valid code cannot be replayed, even
      # under concurrent requests: only the write that advances the watermark
      # wins (1 row affected). Previously the update result was discarded
      # fire-and-forget, so a failed/lost write (or a race) left no watermark and
      # the same 6-digit code could be reused within its ~30s window.
      {count, _} =
        from(u in User,
          where:
            u.id == ^user.id and
              (is_nil(u.totp_last_used_at) or u.totp_last_used_at < ^now)
        )
        |> Repo.update_all(set: [totp_last_used_at: now])

      count == 1
    else
      false
    end
  end

  def valid_totp?(_user, _code), do: false

  @doc "The otpauth:// URI to encode into a QR code for authenticator apps."
  def totp_uri(%User{email: email, totp_secret: secret}) when is_binary(secret),
    do: NimbleTOTP.otpauth_uri("Bunk:" <> email, secret, issuer: "Bunk")

  @doc "The base32 secret for manual entry into an authenticator app."
  def totp_secret_base32(%User{totp_secret: secret}) when is_binary(secret),
    do: Base.encode32(secret, padding: false)

  defp valid_totp_code?(secret, code) when is_binary(code) do
    trimmed = String.trim(code)
    byte_size(trimmed) == 6 and NimbleTOTP.valid?(secret, trimmed)
  end

  defp valid_totp_code?(_secret, _code), do: false

  @doc """
  Registers a new user from `attrs` (`email`, `password`, optionally `name`/`role`).

  Returns `{:ok, user}` or `{:error, changeset}` (e.g. duplicate email, short
  password). The signup bonus is granted on email confirmation (`confirm_user/1`),
  NOT here — crediting it at registration is what let a throwaway, unverified
  address farm free wallet balance (misuse case O-7).
  """
  def register_user(attrs) do
    case %User{} |> User.registration_changeset(attrs) |> Repo.insert() do
      {:ok, user} = ok ->
        deliver_user_confirmation_instructions(user)
        ok

      error ->
        error
    end
  end

  ## Email-link tokens

  # Both email-link flows (confirmation and password reset) are the same four
  # steps, and the steps are only safe in this order: invalidate the older
  # tokens of that context BEFORE minting a new one, so a mailbox never holds
  # two live links and the user can trust that requesting a new link kills the
  # old one. Keeping the sequence in one place is what stops the two flows from
  # drifting — a fix applied to one and forgotten in the other is precisely how
  # a link the system considers revoked stays usable.
  #
  # `deliver` is the `Notifier` entry point for that context, arity 2
  # (user, encoded_token). Mail delivery failures are the Notifier's business;
  # the token is already persisted by then, so the user can always ask for a
  # resend. Returns {:ok, encoded_token} — the raw token exists only here and in
  # the email, never in the database.
  defp issue_email_token(%User{} = user, context, deliver) when is_function(deliver, 2) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, [context]))
    {encoded_token, user_token} = UserToken.build_email_token(user, context)
    Repo.insert!(user_token)
    deliver.(user, encoded_token)
    {:ok, encoded_token}
  end

  ## Email confirmation

  @doc """
  Mints a fresh single-use confirmation token for `user` and emails it. Any
  earlier unconsumed confirmation token for this user is invalidated first, so
  only the most recently sent link works (resending a confirmation email must
  not leave two live links).

  A no-op returning `{:error, :already_confirmed}` for an already-confirmed user
  — resending a confirmation link (or a delayed double-click on "resend") must
  never re-grant the signup bonus or re-send a stale email.
  """
  def deliver_user_confirmation_instructions(%User{confirmed_at: confirmed})
      when not is_nil(confirmed),
      do: {:error, :already_confirmed}

  def deliver_user_confirmation_instructions(%User{} = user),
    do: issue_email_token(user, "confirm", &Notifier.deliver_confirmation_instructions/2)

  @doc """
  Confirms a user from a raw confirmation `token`, atomically stamping
  `confirmed_at`, burning every outstanding confirm token for that user (so the
  same link can't be replayed), and granting the one-time signup bonus — all in
  one transaction so a crediting failure can never leave the account confirmed
  without its bonus, or vice versa.

  Returns `{:ok, user}`, or one of two distinct failures — they are NOT
  interchangeable and callers are expected to treat them differently:

    * `{:error, :invalid_token}` — the link itself is malformed, unknown,
      already used, or expired. The user can fix this by requesting a new one.
    * `{:error, :confirmation_failed}` — the token was good but the write did
      not go through (database trouble, a failing signup-bonus grant, …). The
      account is untouched and the link still works; the fault is ours, it is
      logged at `:error`, and the user should simply retry.

  Collapsing the second case into `:invalid_token` (as this used to) told the
  user their link had expired, sent them chasing a fresh link that would fail
  the same way, and left the real fault silent in the logs.
  """
  def confirm_user(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query) do
      confirm_changeset =
        Ecto.Changeset.change(user, confirmed_at: DateTime.truncate(DateTime.utc_now(), :second))

      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, confirm_changeset)
      |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
      |> Ecto.Multi.run(:bonus, fn _repo, %{user: confirmed_user} ->
        Credits.grant_signup_bonus(confirmed_user.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: confirmed_user}} ->
          {:ok, confirmed_user}

        {:error, step, reason, _changes} ->
          Logger.error(
            "confirm_user/1 failed for user #{user.id} at #{inspect(step)}: #{inspect(reason)}"
          )

          {:error, :confirmation_failed}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def confirm_user(_token), do: {:error, :invalid_token}

  ## Password reset

  @doc """
  Mints a single-use password-reset token for `user` and emails it, invalidating
  any earlier unconsumed reset token first (so requesting a new link kills the
  old one). Returns `{:ok, encoded_token}` — see `request_password_reset/1` for
  the enumeration-safe entry point callers should actually use; this function's
  caller learns whether the account exists (only appropriate once you already
  hold a `%User{}`, e.g. an admin-initiated reset).
  """
  def deliver_user_reset_password_instructions(%User{} = user),
    do: issue_email_token(user, "reset_password", &Notifier.deliver_reset_password_instructions/2)

  @doc """
  Enumeration-safe entry point for "forgot password": looks up `email` and, if
  found, sends a reset link.

  ALWAYS returns `:ok` — for a known address, an unknown one, and a value that
  isn't even a string. That uniform answer is the whole point of the function
  and must survive any future edit: the caller (the public
  `POST /auth/password-reset` endpoint) renders its response straight from this
  result, so the moment a "no such user" leaks out here, the endpoint becomes an
  oracle for which email addresses hold an account.

  Callers that legitimately need to know whether delivery happened already hold
  a `%User{}` and should call `deliver_user_reset_password_instructions/1`.
  """
  def request_password_reset(email) when is_binary(email) do
    case get_user_by_email(String.downcase(email)) do
      %User{} = user ->
        # The delivery result is dropped on purpose — see the docstring. It is
        # never allowed to reach the caller, not even as a success signal.
        _ = deliver_user_reset_password_instructions(user)
        :ok

      nil ->
        :ok
    end
  end

  def request_password_reset(_email), do: :ok

  @doc """
  Returns the user for a valid, unexpired, unused password-reset `token`, or
  `nil`.
  """
  def get_user_by_reset_password_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def get_user_by_reset_password_token(_token), do: nil

  @doc """
  Resets `user`'s password to `attrs["password"]` and, in the same transaction,
  burns the reset token AND every session token (a password reset is exactly the
  "I think someone else has my credentials" moment — leaving old sessions alive
  would defeat the point). Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def reset_user_password(%User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts_query(user, ["reset_password", "session"])
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Sets a user's `role` (`:user`/`:admin`).

  This is the authorized, server-side role-elevation path deliberately kept out of
  the registration changeset (a registrant can never request a role) — an admin
  promotes a user to `:admin` here. Returns `{:ok, user}`.
  """
  def update_user_role(%User{} = user, role) when role in [:user, :admin] do
    user
    |> Ecto.Changeset.change(role: role)
    |> Repo.update()
  end

  @doc """
  Returns the user matching `email`/`password`, or `nil`.

  Runs in (near) constant time whether or not the email exists: when no user is
  found, a dummy pbkdf2 verification is still performed via
  `User.valid_password?/2`.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: String.downcase(email))
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_email_and_password(_email, _password), do: nil

  @doc """
  Generates a new session token for `user`, persists its hash, and returns the raw
  token (the only copy ever returned to the caller).
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns the user owning a valid, non-expired session `token`, or `nil`.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def get_user_by_session_token(_token), do: nil

  @doc """
  Deletes the session identified by `token`. Always returns `:ok`.
  """
  def delete_user_session_token(token) when is_binary(token) do
    hashed_token = :crypto.hash(:sha256, token)
    Repo.delete_all(UserToken.by_token_and_context_query(hashed_token, "session"))
    :ok
  end

  def delete_user_session_token(_token), do: :ok

  @doc """
  Revokes all of `user`'s session tokens ("log out everywhere"). Use this as the
  kill switch for a leaked token and on any future password change. Always `:ok`.
  """
  def delete_all_user_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end
end
