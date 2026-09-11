defmodule ControlPlane.AccountsRegistrationTest do
  @moduledoc "Boundary validation for self-registration (guards against oversized input)."
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts

  describe "register_user/1 input validation" do
    test "rejects an over-long name instead of 500-ing on the DB column limit" do
      attrs = %{
        name: String.duplicate("a", 200_000),
        email: "n1@bunk.test",
        password: "ValidPass123!"
      }

      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "should be at most 100 character(s)" in errors_on(changeset).name
    end

    test "trims surrounding whitespace from the name" do
      {:ok, user} =
        Accounts.register_user(%{
          name: "  Alice  ",
          email: "n2@bunk.test",
          password: "ValidPass123!"
        })

      assert user.name == "Alice"
    end

    test "still rejects a weak password and a malformed email" do
      assert {:error, _} =
               Accounts.register_user(%{name: "A", email: "n3@bunk.test", password: "short"})

      assert {:error, _} =
               Accounts.register_user(%{name: "A", email: "no-at-sign", password: "ValidPass123!"})
    end
  end
end
