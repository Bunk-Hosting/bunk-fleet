defmodule ControlPlane.TurnstileTest do
  @moduledoc """
  Server-side CAPTCHA verification.

  The widget in the browser stops nobody: a bot calls the JSON API directly and
  never loads it. This check is the part that counts, and its two most important
  behaviours are the least obvious ones — it is a no-op when no secret is
  configured, and it fails CLOSED when Cloudflare cannot be reached.
  """
  use ExUnit.Case, async: false

  alias ControlPlane.Turnstile

  setup do
    original = Application.get_env(:control_plane, :turnstile)
    on_exit(fn -> Application.put_env(:control_plane, :turnstile, original) end)
    :ok
  end

  defp enable(stub) do
    Req.Test.stub(Turnstile, stub)

    Application.put_env(:control_plane, :turnstile,
      secret_key: "test-secret",
      req_options: [plug: {Req.Test, Turnstile}]
    )
  end

  defp disable, do: Application.put_env(:control_plane, :turnstile, secret_key: nil)

  test "with no secret configured every token passes" do
    disable()

    assert Turnstile.verify("anything") == :ok
    assert Turnstile.verify(nil) == :ok
    assert Turnstile.verify("") == :ok
    refute Turnstile.enabled?()
  end

  test "a token Cloudflare confirms is accepted" do
    enable(fn conn -> Req.Test.json(conn, %{"success" => true}) end)

    assert Turnstile.enabled?()
    assert Turnstile.verify("good-token") == :ok
  end

  test "a token Cloudflare rejects is refused" do
    enable(fn conn ->
      Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-response"]})
    end)

    assert Turnstile.verify("forged-token") == {:error, :captcha_failed}
  end

  test "a missing token is refused before any call is made" do
    enable(fn _conn -> raise "Cloudflare was called for a token that was never sent" end)

    assert Turnstile.verify(nil) == {:error, :captcha_required}
    assert Turnstile.verify("") == {:error, :captcha_required}
    assert Turnstile.verify(123) == {:error, :captcha_required}
  end

  test "an unreachable Cloudflare refuses rather than admits" do
    # Failing open here would mean a bot only has to make siteverify unreachable
    # — or wait for Cloudflare to have a bad day — to walk straight through.
    enable(fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert Turnstile.verify("token") == {:error, :captcha_unavailable}
  end

  test "the caller's IP is forwarded when there is one" do
    test_pid = self()

    enable(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:form, URI.decode_query(body)})
      Req.Test.json(conn, %{"success" => true})
    end)

    assert Turnstile.verify("token", "203.0.113.9") == :ok
    assert_receive {:form, form}
    assert form["remoteip"] == "203.0.113.9"
    assert form["response"] == "token"
    assert form["secret"] == "test-secret"
  end

  test "no IP means no remoteip field rather than an empty one" do
    test_pid = self()

    enable(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:form, URI.decode_query(body)})
      Req.Test.json(conn, %{"success" => true})
    end)

    assert Turnstile.verify("token") == :ok
    assert_receive {:form, form}
    refute Map.has_key?(form, "remoteip")
  end
end
