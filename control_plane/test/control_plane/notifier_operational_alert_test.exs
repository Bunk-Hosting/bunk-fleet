defmodule ControlPlane.NotifierOperationalAlertTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias ControlPlane.Notifier

  setup do
    previous = Application.get_env(:control_plane, :ops_email)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:control_plane, :ops_email)
  defp restore(value), do: Application.put_env(:control_plane, :ops_email, value)

  test "mails the operator, tagged so it filters away from customer mail" do
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")

    assert :ok = Notifier.deliver_operational_alert("backup failed on vm102", "the evidence")

    assert_email_sent(fn email ->
      assert {_name, _from} = email.from
      assert [{_, "ops@bunk.test"}] = email.to
      assert email.subject == "[Bunk] backup failed on vm102"
      assert email.text_body =~ "the evidence"
    end)
  end

  test "an alert has no empty HTML part" do
    # Swoosh would otherwise send an empty html_body, which some clients render
    # as a blank message — exactly the wrong thing for the one email that has to
    # be read.
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")

    assert :ok = Notifier.deliver_operational_alert("subject", "body")
    assert_email_sent(fn email -> assert is_nil(email.html_body) end)
  end

  test "says so rather than pretending, when no operator address is configured" do
    Application.delete_env(:control_plane, :ops_email)

    assert {:error, :no_ops_email} = Notifier.deliver_operational_alert("subject", "body")
  end

  test "an empty configured address is treated as unset" do
    Application.put_env(:control_plane, :ops_email, "")

    assert {:error, :no_ops_email} = Notifier.deliver_operational_alert("subject", "body")
  end
end
