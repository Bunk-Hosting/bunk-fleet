defmodule ControlPlane.Mailer.ConfigTest do
  # Pure logic: no database, no application state, no OS environment.
  use ExUnit.Case, async: true

  alias ControlPlane.Mailer.Config

  @host "smtp.example.com"

  # Every case shares a host; the interesting input is the rest of the env.
  defp build(env \\ %{}) do
    env
    |> Map.put("SMTP_HOST", @host)
    |> Config.smtp_options()
  end

  describe "transport basics" do
    test "carries the adapter, relay and credentials through" do
      opts = build(%{"SMTP_USERNAME" => "bunk", "SMTP_PASSWORD" => "hunter2"})

      assert opts[:adapter] == Swoosh.Adapters.SMTP
      assert opts[:relay] == @host
      assert opts[:username] == "bunk"
      assert opts[:password] == "hunter2"
      # Never downgrade to an unauthenticated send, and don't give up after one
      # transient network hiccup.
      assert opts[:auth] == :always
      assert opts[:retries] == 2
    end

    test "defaults to the STARTTLS submission port when SMTP_PORT is unset" do
      assert build()[:port] == 587
    end

    test "parses SMTP_PORT as an integer" do
      assert build(%{"SMTP_PORT" => "2525"})[:port] == 2525
    end

    test "missing credentials stay nil rather than becoming empty strings" do
      assert build()[:username] == nil
      assert build()[:password] == nil
    end

    test "requires a host" do
      assert_raise ArgumentError, fn -> Config.smtp_options(%{}) end
    end

    test "accepts any enumerable of name/value pairs, not just a map" do
      opts = Config.smtp_options([{"SMTP_HOST", @host}, {"SMTP_PORT", "465"}])

      assert opts[:relay] == @host
      assert opts[:port] == 465
      assert opts[:ssl] == true
    end
  end

  describe "TLS mode" do
    # The whole point of this module: the CA options have to land under the key
    # gen_smtp actually reads for the mode in use, and under no other.
    test "port 465 is implicit SSL with the CA options in :sockopts only" do
      opts = build(%{"SMTP_PORT" => "465"})

      assert opts[:ssl] == true
      assert opts[:tls] == :never
      assert is_list(opts[:sockopts])
      assert opts[:sockopts][:verify] == :verify_peer
      # :tls_options here would be dead weight; worse, it hides a wrong mode.
      assert opts[:tls_options] == nil
    end

    test "port 587 upgrades via STARTTLS with the CA options in :tls_options only" do
      opts = build(%{"SMTP_PORT" => "587"})

      assert opts[:ssl] == false
      assert opts[:tls] == :always
      assert is_list(opts[:tls_options])
      assert opts[:tls_options][:verify] == :verify_peer
      # :sockopts is passed to a plain gen_tcp connect in this mode, where SSL
      # options are an error — it must be absent.
      assert opts[:sockopts] == nil
    end

    test "SMTP_SSL forces implicit SSL on a port that would otherwise STARTTLS" do
      for flag <- ["1", "true"] do
        opts = build(%{"SMTP_PORT" => "587", "SMTP_SSL" => flag})

        assert opts[:ssl] == true
        assert opts[:tls] == :never
        assert is_list(opts[:sockopts])
        assert opts[:tls_options] == nil
        # The override changes the TLS mode, not where we connect.
        assert opts[:port] == 587
      end
    end

    test "SMTP_SSL forces STARTTLS on a port that would otherwise be implicit SSL" do
      for flag <- ["0", "false"] do
        opts = build(%{"SMTP_PORT" => "465", "SMTP_SSL" => flag})

        assert opts[:ssl] == false
        assert opts[:tls] == :always
        assert is_list(opts[:tls_options])
        assert opts[:sockopts] == nil
        assert opts[:port] == 465
      end
    end

    test "an unrecognised SMTP_SSL value falls back to the port" do
      assert build(%{"SMTP_PORT" => "465", "SMTP_SSL" => "yes please"})[:ssl] == true
      assert build(%{"SMTP_PORT" => "587", "SMTP_SSL" => "yes please"})[:ssl] == false
    end
  end

  describe "certificate verification" do
    test "verifies the peer against a CA bundle in both modes" do
      for {port, key} <- [{"465", :sockopts}, {"587", :tls_options}] do
        ca_opts = build(%{"SMTP_PORT" => port})[key]

        assert ca_opts[:verify] == :verify_peer
        assert ca_opts[:depth] == 4
        assert is_binary(ca_opts[:cacertfile])
        assert ca_opts[:cacertfile] != ""
      end
    end

    test "SMTP_CACERTFILE overrides the bundle castore would resolve" do
      ca_opts = build(%{"SMTP_CACERTFILE" => "/custom/ca.pem"})[:tls_options]

      assert ca_opts[:cacertfile] == "/custom/ca.pem"
      refute ca_opts[:cacertfile] == Config.cacertfile(nil)
    end

    test "falls back to a resolvable bundle when SMTP_CACERTFILE is unset" do
      # castore is a dependency here, so this should be its pinned bundle; what
      # matters is that the resolution never raises and never yields nil.
      assert is_binary(Config.cacertfile(nil))
    end

    test "SNI is the host as a charlist, which is what :ssl expects" do
      ca_opts = build()[:tls_options]

      assert ca_opts[:server_name_indication] == ~c"smtp.example.com"
      assert is_list(ca_opts[:server_name_indication])
    end

    test "hostname checking uses the https match fun" do
      ca_opts = build()[:tls_options]

      assert is_function(ca_opts[:customize_hostname_check][:match_fun])
    end
  end
end
