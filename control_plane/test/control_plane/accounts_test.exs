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
  end
end
