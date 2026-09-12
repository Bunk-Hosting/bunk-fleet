defmodule ControlPlane.LoginThrottleTest do
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.LoginThrottle

  @password "test-only-password-4f2b9c1e"

  defp user do
    email = "throttle-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp fail(email, n),
    do: Enum.each(1..n, fn _ -> Accounts.get_user_by_email_and_password(email, "wrong") end)

  test "a fumbled password costs nothing" do
    u = user()
    fail(u.email, 4)

    refute LoginThrottle.blocked?(u.email)
    assert %Accounts.User{} = Accounts.get_user_by_email_and_password(u.email, @password)
  end

  test "five failures buy a window, and the right password does not open it" do
    u = user()
    fail(u.email, 5)

    assert LoginThrottle.blocked?(u.email)
    # Indistinguishable from a wrong password: no oracle for which accounts exist.
    assert Accounts.get_user_by_email_and_password(u.email, @password) == nil
  end

  test "a successful login before the threshold forgets the failures" do
    u = user()
    fail(u.email, 4)
    assert %Accounts.User{} = Accounts.get_user_by_email_and_password(u.email, @password)

    fail(u.email, 4)
    refute LoginThrottle.blocked?(u.email)
  end

  test "the window widens as failures accumulate" do
    u = user()
    fail(u.email, 5)
    assert LoginThrottle.blocked?(u.email)

    # Nothing here waits out a window — the point is that more failures never
    # shorten one, which is what an attacker would need.
    fail(u.email, 15)
    assert LoginThrottle.blocked?(u.email)
  end

  test "the throttle follows the account, not the attempt's casing" do
    u = user()
    fail(String.upcase(u.email), 5)

    assert LoginThrottle.blocked?(u.email)
  end

  test "one account's failures leave every other account alone" do
    victim = user()
    bystander = user()
    fail(victim.email, 10)

    refute LoginThrottle.blocked?(bystander.email)
    assert %Accounts.User{} = Accounts.get_user_by_email_and_password(bystander.email, @password)
  end

  test "an address that was never registered is throttled too" do
    # Otherwise the throttle itself is the oracle: real accounts slow down after
    # five wrong guesses and made-up ones do not.
    nobody = "nobody-#{System.unique_integer([:positive])}@example.com"
    fail(nobody, 5)

    assert LoginThrottle.blocked?(nobody)
  end
end
