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

  @doc """
  Registers a new user from `attrs` (`email`, `password`, optionally `name`/`role`).

  Returns `{:ok, user}` or `{:error, changeset}` (e.g. duplicate email, short
  password).
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
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
