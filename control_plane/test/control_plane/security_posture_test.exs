defmodule ControlPlane.SecurityPostureTest do
  @moduledoc """
  The boot-time report on protections that are switched off.

  Its whole reason to exist is that these defences fail open: the request
  succeeds, the alert is simply not sent, and nothing says so. If this module
  ever quietly reports "all good" while a secret is missing, the gap goes back to
  being invisible — which is the state it was built to end.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ControlPlane.SecurityPosture

  setup do
    turnstile = Application.get_env(:control_plane, :turnstile)
    mollie = Application.get_env(:control_plane, :mollie)
    ops = Application.get_env(:control_plane, :ops_email)

    on_exit(fn ->
      Application.put_env(:control_plane, :turnstile, turnstile)
      Application.put_env(:control_plane, :mollie, mollie)
      Application.put_env(:control_plane, :ops_email, ops)
    end)

    :ok
  end

  defp configure(turnstile_secret, ops_email, mollie_key) do
    Application.put_env(:control_plane, :turnstile, secret_key: turnstile_secret)
    Application.put_env(:control_plane, :ops_email, ops_email)
    Application.put_env(:control_plane, :mollie, api_key: mollie_key)
  end

  test "everything configured reports nothing" do
    configure("secret", "ops@bunkhosting.nl", "test_key")

    log = capture_log(fn -> assert SecurityPosture.report() == [] end)
    refute log =~ "security posture"
  end

  test "a missing Turnstile secret is named, not just skipped" do
    configure(nil, "ops@bunkhosting.nl", "test_key")

    log = capture_log(fn -> assert SecurityPosture.report() == [:turnstile] end)
    assert log =~ "TURNSTILE_SECRET_KEY"
    # The message has to say what is exposed, not only which variable is unset.
    assert log =~ "signup bonus"
  end

  test "a missing ops address is named" do
    configure("secret", nil, "test_key")

    log = capture_log(fn -> assert SecurityPosture.report() == [:ops_email] end)
    assert log =~ "OPS_EMAIL"
  end

  test "an empty string counts as unset" do
    # A compose file with `OPS_EMAIL=` is the most likely way to end up here, and
    # it must not read as configured.
    configure("", "", "")

    assert SecurityPosture.report() == [:turnstile, :ops_email, :mollie]
  end

  test "several gaps are all reported, not just the first" do
    configure(nil, nil, nil)

    log = capture_log(fn -> assert length(SecurityPosture.report()) == 3 end)
    assert log =~ "TURNSTILE_SECRET_KEY"
    assert log =~ "OPS_EMAIL"
    assert log =~ "MOLLIE_API_KEY"
  end
end
