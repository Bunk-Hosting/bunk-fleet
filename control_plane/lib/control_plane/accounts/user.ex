defmodule ControlPlane.Accounts.User do
  @moduledoc """
  A human identity (customer or staff) that authenticates to the control-plane
  API with an email + password and acts as `conn.assigns.current_user`.

  Only the pbkdf2 `hashed_password` is persisted; the plaintext `password` is a
  virtual field present only while a registration changeset is being built, and is
  cleared as soon as it has been hashed. Both are `redact: true` so they never leak
  into logs or inspect output.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :role, Ecto.Enum, values: [:user, :admin], default: :user
    field :name, :string
    field :confirmed_at, :utc_datetime
    field :totp_secret, :binary, redact: true
    field :totp_confirmed_at, :utc_datetime
    field :totp_last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering a new user.

  Validates and normalises the email, requires a password of at least 12
  characters, and hashes that password into `hashed_password` (clearing the virtual
  `password`). The unique-email constraint is enforced both here (for a friendly
  error) and at the DB level.
  """
  def registration_changeset(user, attrs) do
    user
    # SECURITY: never cast :role from self-registration input — everyone signs up
    # as the default :user. Role elevation (:admin) is an explicit,
    # authorized server-side action, not something a registrant can request.
    |> cast(attrs, [:email, :password, :name])
    |> validate_email()
    |> validate_password()
    |> validate_name()
    |> hash_password()
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, max: 100)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
    |> unsafe_validate_unique(:email, ControlPlane.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
  end

  @doc """
  Changeset for setting a new password (password reset / change), independent of
  registration — it never touches `:email` or `:role`, so this is the only field
  a caller can move via this path.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
    |> hash_password()
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies a plaintext `password` against a user's stored `hashed_password`.

  When given `nil` (no such user) it still runs a dummy `Pbkdf2.no_user_verify/0`
  so the response time does not reveal whether the email exists.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_user, _password) do
    Pbkdf2.no_user_verify()
    false
  end
end
