defmodule ControlPlaneWeb.ConsoleMessageTest do
  @moduledoc """
  What the terminal says when a console session ends badly.

  A console that closes without a word leaves the customer looking at a black
  rectangle and the frontend's generic "Verbinding verbroken", with no way to
  tell their machine still booting apart from the platform being broken. The
  most common cause by far is the first one: a VPS provisioned a minute ago
  whose sshd is not listening yet.
  """
  use ExUnit.Case, async: true

  alias ControlPlaneWeb.ConsoleSocket

  defp message(reason) do
    {:push, {:binary, text}, {:stop, :normal, _}} =
      ConsoleSocket.handle_info({:console_closed, reason}, %{})

    text
  end

  test "a refused connection says the machine is probably still booting" do
    text = message(:econnrefused)

    assert text =~ "reageert nog niet op SSH"
    # The next step, not just the diagnosis.
    assert text =~ "opnieuw"
  end

  test "a changed host key names the one innocent explanation and warns about the rest" do
    text = message({:host_key_mismatch, "SHA256:whatever"})

    assert text =~ "veranderd"
    assert text =~ "back-up"
    assert text =~ "contact op"
  end

  test "a missing console key says it is our fault" do
    assert message(:no_console_key) =~ "storing bij ons"
  end

  test "an unknown reason still produces something to act on, not an atom" do
    text = message(:something_nobody_anticipated)

    # The catch-all covers every way an SSH handshake can fail after the node
    # attached; it has to name the likely cause and a next step, because a bare
    # "de verbinding is verbroken" leaves the customer with nothing to try.
    assert text =~ "geen verbinding maken"
    assert text =~ "opnieuw"
    refute text =~ "something_nobody_anticipated"
  end

  test "every message is framed so a terminal renders it" do
    for reason <- [:econnrefused, :etimedout, :no_console_key, :relay_timeout, :bang] do
      text = message(reason)

      # CRLF, because the far end is a terminal in raw mode where a bare newline
      # drops a row without returning to column one.
      assert String.starts_with?(text, "\r\n")
      assert String.ends_with?(text, "\r\n")
      # Red, and reset afterwards so the colour does not bleed into the rest.
      assert text =~ "\e[31m"
      assert text =~ "\e[0m"
    end
  end

  test "the reason never reaches the customer as a raw term" do
    # A leaked {:host_key_mismatch, fingerprint} or an Erlang posix atom is noise
    # to the person reading it and detail to anyone else looking over their
    # shoulder.
    for reason <- [:econnrefused, :etimedout, {:host_key_mismatch, "SHA256:abc"}] do
      text = message(reason)
      refute text =~ "SHA256:abc"
      refute text =~ ":"
    end
  end
end
