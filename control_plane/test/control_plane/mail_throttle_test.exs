defmodule ControlPlane.MailThrottleTest do
  @moduledoc """
  How many emails one account can cause us to send.

  The endpoint that resends a confirmation sits behind authentication but had no
  limit, and registration is open to anyone — so a single account could ask the
  platform to send an unbounded number of messages. The damage is not to the
  endpoint: thousands of messages from one sender in a minute is how a mail
  provider decides a domain is a spammer, and then nobody gets a confirmation, a
  reset or an ops alert until someone argues us back off a blocklist.
  """
  use ControlPlane.DataCase, async: false

  import Swoosh.TestAssertions

  alias ControlPlane.Accounts
  alias ControlPlane.RateLimiter

  @password "test-only-password-4f2b9c1e"

  setup do
    RateLimiter.reset()

    email = "mail-throttle-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    # register_user sends the first confirmation itself.
    assert_email_sent()

    %{user: user, email: email}
  end

  test "a handful of resends still go out", %{user: user} do
    # Someone who did not get the first mail and clicks again must not be
    # stopped; four more is well inside anything a person does.
    for _ <- 1..4 do
      assert {:ok, _} = Accounts.deliver_user_confirmation_instructions(user)
      assert_email_sent()
    end
  end

  test "past the cap nothing more is sent", %{user: user} do
    for _ <- 1..4, do: Accounts.deliver_user_confirmation_instructions(user)
    # The four above legitimately went out; refute_email_sent/0 looks at the whole
    # mailbox, so they have to be taken off it before it can mean anything.
    drain_emails()

    for _ <- 1..20 do
      assert {:ok, :throttled} = Accounts.deliver_user_confirmation_instructions(user)
    end

    refute_email_sent()
  end

  test "a throttled resend does not invalidate the link the person already has", %{user: user} do
    # Every successful resend replaces the previous link on purpose, so the one
    # that matters is the last one that actually went out. What must not happen
    # is a REFUSED send burning it: that would turn rate limiting into a way to
    # lock someone out of their own confirmation.
    last =
      Enum.reduce(1..4, nil, fn _, acc ->
        case Accounts.deliver_user_confirmation_instructions(user) do
          {:ok, token} when is_binary(token) -> token
          _ -> acc
        end
      end)

    for _ <- 1..20, do: Accounts.deliver_user_confirmation_instructions(user)

    assert {:ok, confirmed} = Accounts.confirm_user(last)
    assert confirmed.id == user.id
  end

  test "password resets share the budget per kind, not across kinds", %{email: email} do
    # Confirmations and resets are counted separately: exhausting one must not
    # lock a customer out of the other.
    for _ <- 1..10, do: Accounts.request_password_reset(email)
    drain_emails()

    # Reset mails stop at the cap of their own kind: the five past it send
    # nothing, while the confirmation budget is untouched.
    for _ <- 1..5, do: Accounts.request_password_reset(email)
    refute_email_sent()
  end

  test "one account's budget is its own", %{user: user} do
    other_email = "other-#{System.unique_integer([:positive])}@example.com"
    {:ok, other} = Accounts.register_user(%{email: other_email, password: @password})
    assert_email_sent()

    for _ <- 1..20, do: Accounts.deliver_user_confirmation_instructions(user)

    # An attacker burning their own budget must not stop anyone else's mail.
    assert {:ok, token} = Accounts.deliver_user_confirmation_instructions(other)
    assert is_binary(token)
    assert_email_sent()
  end

  # Swoosh's test adapter delivers into this process's mailbox and
  # refute_email_sent/0 inspects all of it, so anything that legitimately went
  # out earlier in a test has to be taken off first.
  defp drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end

  test "the reset endpoint still tells a caller nothing", %{email: email} do
    # Throttled or not, the answer is the same :ok — that is what stops this
    # endpoint being used to find out which addresses have an account.
    assert Accounts.request_password_reset(email) == :ok
    for _ <- 1..20, do: assert(Accounts.request_password_reset(email) == :ok)
    assert Accounts.request_password_reset("nobody-at-all@example.com") == :ok
  end
end
