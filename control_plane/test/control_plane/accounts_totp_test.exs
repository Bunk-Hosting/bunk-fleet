defmodule ControlPlane.AccountsTotpTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Rookworst31!secure"})
    u
  end

  test "setup -> confirm -> active lifecycle" do
    u = user("t1@bunk.test")
    refute Accounts.totp_active?(u)

    u = Accounts.start_totp_setup(u)
    assert is_binary(u.totp_secret)
    refute Accounts.totp_active?(u), "unconfirmed secret must not count as active"

    {:ok, u} = Accounts.confirm_totp(u, NimbleTOTP.verification_code(u.totp_secret))
    assert Accounts.totp_active?(u)

    assert Accounts.valid_totp?(u, NimbleTOTP.verification_code(u.totp_secret))
    refute Accounts.valid_totp?(u, "000000")

    {:ok, u} = Accounts.disable_totp(u)
    refute Accounts.totp_active?(u)
    assert is_nil(u.totp_secret)
  end

  test "confirm with a wrong code fails" do
    u = user("t2@bunk.test") |> Accounts.start_totp_setup()
    assert {:error, :invalid_code} = Accounts.confirm_totp(u, "000000")
    refute Accounts.totp_active?(Accounts.get_user!(u.id))
  end

  test "valid_totp? is false for users without TOTP" do
    refute Accounts.valid_totp?(user("t3@bunk.test"), "123456")
  end
end
