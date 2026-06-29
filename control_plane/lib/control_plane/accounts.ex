defmodule ControlPlane.Accounts do
  @moduledoc """
  User identity and authentication for the control-plane API.

  Handles registration (pbkdf2 password hashing), email + password login with
  constant-time comparison, and bearer session tokens. Session tokens are stored
  hashed at rest — see `ControlPlane.Accounts.UserToken` — and the raw token is
  returned to the caller exactly once at generation time.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Repo
  alias ControlPlane.Accounts.{User, UserToken}

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

    if byte_size(trimmed) == 6 and NimbleTOTP.valid?(secret, trimmed, since: user.totp_last_used_at) do
      user
      |> Ecto.Changeset.change(totp_last_used_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()

      true
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
  password).
  """
  def register_user(attrs) do
    case %User{} |> User.registration_changeset(attrs) |> Repo.insert() do
      {:ok, user} = ok ->
        ControlPlane.Credits.grant_signup_bonus(user.id)
        ok

      error ->
        error
    end
  end

  @doc """
  Sets a user's `role` (`:user`/`:operator`/`:admin`).

  This is the authorized, server-side role-elevation path deliberately kept out of
  the registration changeset (a registrant can never request a role) — an admin
  promotes a user to `:operator`/`:admin` here. Returns `{:ok, user}`.
  """
  def update_user_role(%User{} = user, role) when role in [:user, :operator, :admin] do
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
