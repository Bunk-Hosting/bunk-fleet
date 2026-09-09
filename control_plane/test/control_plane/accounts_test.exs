defmodule ControlPlane.AccountsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User

  @valid_email "operator@example.com"
  @valid_password "super-secret-pw-123"

  defp register_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: @valid_email, password: @valid_password, name: "Op"})
      |> Accounts.register_user()

    user
  end

  describe "register_user/1" do
    test "creates a user and hashes the password" do
      assert {:ok, %User{} = user} =
               Accounts.register_user(%{email: @valid_email, password: @valid_password})

      assert user.email == @valid_email
      assert user.role == :user
      # Plaintext is never stored, and the hash is not the plaintext.
      assert is_binary(user.hashed_password)
      refute user.hashed_password == @valid_password
      assert is_nil(user.password)
      assert User.valid_password?(user, @valid_password)
    end

    test "downcases the email" do
      assert {:ok, user} =
               Accounts.register_user(%{email: "Mixed@Example.COM", password: @valid_password})

      assert user.email == "mixed@example.com"
    end

    test "rejects a password shorter than 12 characters" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: @valid_email, password: "short"})

      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
    end

    test "rejects a missing or malformed email" do
      assert {:error, changeset} = Accounts.register_user(%{password: @valid_password})
      assert %{email: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.register_user(%{email: "not an email", password: @valid_password})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "rejects a duplicate email" do
      _user = register_fixture()

      assert {:error, changeset} =
               Accounts.register_user(%{email: @valid_email, password: @valid_password})

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_user_by_email_and_password/2" do
    setup do
      %{user: register_fixture()}
    end

    test "returns the user with the right password", %{user: user} do
      assert found = Accounts.get_user_by_email_and_password(@valid_email, @valid_password)
      assert found.id == user.id
    end

    test "returns nil with the wrong password" do
      refute Accounts.get_user_by_email_and_password(@valid_email, "wrong-password-xx")
    end

    test "returns nil for an unknown email" do
      refute Accounts.get_user_by_email_and_password("nobody@example.com", @valid_password)
    end
  end

  describe "session tokens" do
    setup do
      %{user: register_fixture()}
    end

    test "generate -> get_user_by_session_token round-trips", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert is_binary(token)

      assert found = Accounts.get_user_by_session_token(token)
      assert found.id == user.id
    end

    test "the token is stored hashed, not in plaintext", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      stored = Repo.one(ControlPlane.Accounts.UserToken)
      assert stored.token == :crypto.hash(:sha256, token)
      refute stored.token == token
    end

    test "delete invalidates the token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token)

      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "delete_all revokes every session of the user", %{user: user} do
      t1 = Accounts.generate_user_session_token(user)
      t2 = Accounts.generate_user_session_token(user)
      other = register_fixture(%{email: "other@example.com"})
      t_other = Accounts.generate_user_session_token(other)

      assert :ok = Accounts.delete_all_user_session_tokens(user)

      refute Accounts.get_user_by_session_token(t1)
      refute Accounts.get_user_by_session_token(t2)
      # Another user's sessions are untouched.
      assert Accounts.get_user_by_session_token(t_other)
    end
  end

  describe "email confirmation" do
    test "register_user sends a confirmation email but grants no bonus yet" do
      user = register_fixture(%{email: "confirm1@example.com"})
      assert is_nil(user.confirmed_at)
      assert ControlPlane.Credits.balance_cents(user.id) == 0
    end

    test "confirm_user/1 stamps confirmed_at and grants the signup bonus exactly once" do
      user = register_fixture(%{email: "confirm2@example.com"})
      {:ok, token} = Accounts.deliver_user_confirmation_instructions(user)

      assert {:ok, confirmed} = Accounts.confirm_user(token)
      assert confirmed.confirmed_at
      assert ControlPlane.Credits.balance_cents(user.id) == ControlPlane.Credits.signup_bonus_cents()

      # The token is single-use: replaying it (e.g. a link opened twice) must not
      # re-grant the bonus.
      assert {:error, :invalid_token} = Accounts.confirm_user(token)
      assert ControlPlane.Credits.balance_cents(user.id) == ControlPlane.Credits.signup_bonus_cents()
    end

    test "confirm_user/1 rejects an unknown or malformed token" do
      assert {:error, :invalid_token} = Accounts.confirm_user("not-a-real-token")
    end

    test "deliver_user_confirmation_instructions/1 invalidates the previous token on resend" do
      user = register_fixture(%{email: "confirm3@example.com"})
      {:ok, old_token} = Accounts.deliver_user_confirmation_instructions(user)
      {:ok, new_token} = Accounts.deliver_user_confirmation_instructions(user)

      assert {:error, :invalid_token} = Accounts.confirm_user(old_token)
      assert {:ok, _} = Accounts.confirm_user(new_token)
    end

    test "deliver_user_confirmation_instructions/1 refuses an already-confirmed user" do
      user = register_fixture(%{email: "confirm4@example.com"})
      {:ok, token} = Accounts.deliver_user_confirmation_instructions(user)
      {:ok, confirmed} = Accounts.confirm_user(token)

      assert {:error, :already_confirmed} = Accounts.deliver_user_confirmation_instructions(confirmed)
    end
  end

  describe "password reset" do
    test "request_password_reset/1 always returns :ok, matching or not" do
      register_fixture(%{email: "reset1@example.com"})
      assert :ok = Accounts.request_password_reset("reset1@example.com")
      assert :ok = Accounts.request_password_reset("nobody-at-all@example.com")
    end

    test "get_user_by_reset_password_token/1 resolves a valid token, nil otherwise" do
      user = register_fixture(%{email: "reset2@example.com"})
      {:ok, token} = Accounts.deliver_user_reset_password_instructions(user)

      assert %User{id: id} = Accounts.get_user_by_reset_password_token(token)
      assert id == user.id
      assert is_nil(Accounts.get_user_by_reset_password_token("garbage"))
    end

    test "reset_user_password/2 changes the password and revokes every session, including the reset token" do
      user = register_fixture(%{email: "reset3@example.com"})
      session_token = Accounts.generate_user_session_token(user)
      {:ok, reset_token} = Accounts.deliver_user_reset_password_instructions(user)

      assert {:ok, updated} = Accounts.reset_user_password(user, %{"password" => "brand-new-pw-123"})
      assert User.valid_password?(updated, "brand-new-pw-123")
      refute User.valid_password?(updated, @valid_password)

      # Old session is dead...
      refute Accounts.get_user_by_session_token(session_token)
      # ...and so is the reset token itself (can't be replayed).
      assert is_nil(Accounts.get_user_by_reset_password_token(reset_token))
    end

    test "reset_user_password/2 rejects a too-short password without touching sessions" do
      user = register_fixture(%{email: "reset4@example.com"})
      session_token = Accounts.generate_user_session_token(user)

      assert {:error, changeset} = Accounts.reset_user_password(user, %{"password" => "short"})
      assert %{password: [_ | _]} = errors_on(changeset)
      assert Accounts.get_user_by_session_token(session_token)
    end

    test "a fresh reset request invalidates the previous reset link" do
      user = register_fixture(%{email: "reset5@example.com"})
      {:ok, old_token} = Accounts.deliver_user_reset_password_instructions(user)
      {:ok, new_token} = Accounts.deliver_user_reset_password_instructions(user)

      assert is_nil(Accounts.get_user_by_reset_password_token(old_token))
      assert Accounts.get_user_by_reset_password_token(new_token)
    end
  end
end
