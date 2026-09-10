defmodule ControlPlane.CreditsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.{Accounts, Credits}

  # The signup bonus is granted on email confirmation, not at registration (see
  # Accounts.confirm_user/1) — go through the real confirmation flow so these
  # tests exercise the actual path a credited user takes, not a shortcut.
  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Rookworst31!secure"})
    {:ok, token} = Accounts.deliver_user_confirmation_instructions(u)
    {:ok, confirmed} = Accounts.confirm_user(token)
    confirmed
  end

  test "new user receives the signup bonus" do
    u = user("c1@bunk.test")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "the signup bonus is granted at most once, whatever the caller does" do
    u = user("c1b@bunk.test")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()

    # A pre-confirmation-era account carries a bonus but no confirmed_at, so
    # confirming later must not top it up a second time.
    assert {:ok, nil} = Credits.grant_signup_bonus(u.id)
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "charge debits when affordable, rejects when not, and is atomic" do
    u = user("c2@bunk.test")
    assert {:ok, _} = Credits.charge(u.id, 300, "vps_charge", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents() - 300

    {:ok, _} = Credits.charge(u.id, Credits.balance_cents(u.id), "drain", "x")
    assert Credits.balance_cents(u.id) == 0
    assert {:error, :insufficient_credits} = Credits.charge(u.id, 1, "vps_charge", "x")
    # rejected charge left no entry
    assert Credits.balance_cents(u.id) == 0
  end

  test "zero/under charge is a free no-op" do
    u = user("c3@bunk.test")
    assert {:ok, nil} = Credits.charge(u.id, 0, "free", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "refund credits back" do
    u = user("c4@bunk.test")
    {:ok, _} = Credits.charge(u.id, 300, "vps_charge", "x")
    {:ok, _} = Credits.refund(u.id, 300, "vps_refund", "x")
    assert Credits.balance_cents(u.id) == Credits.signup_bonus_cents()
  end

  test "list_entries returns newest first" do
    u = user("c5@bunk.test")
    {:ok, _} = Credits.charge(u.id, 100, "later", "second")
    assert hd(Credits.list_entries(u.id)).kind == "later"
  end
end
