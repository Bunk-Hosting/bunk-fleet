defmodule ControlPlane.ConsoleKeyCbTest do
  @moduledoc """
  The `:ssh_client_key_api` callback the browser console's SSH client runs on.

  OTP asks this module two questions per connection: which private key to
  authenticate with, and whether to trust the host key the far end presented. The
  second one is the whole MITM defence — the node operator controls the
  hypervisor, the network and the relay every console byte travels through, so
  "is this the machine we pinned?" is the only question standing between them and
  a customer's session.

  The failure mode that matters is failing OPEN. `is_host_key/5` runs inside
  OTP's SSH machinery; anything it raises would otherwise escape into a code path
  that was never written to expect it, so it rescues and rejects instead.
  """
  use ControlPlane.DataCase, async: false

  import ExUnit.CaptureLog

  alias ControlPlane.Console.HostKeys
  alias ControlPlane.Console.KeyCb
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  setup_all do
    # Real keys, because the fingerprints have to be ones OTP can actually
    # compute — not strings that merely look like fingerprints. RSA rather than
    # ed25519 so the same key round-trips through :public_key's PEM encoder,
    # which is what the console's private key arrives as.
    %{host: generate_key(), other: generate_key(), console: generate_key()}
  end

  defp generate_key do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    {public, private}
  end

  defp public({pub, _priv}), do: pub

  defp opts(private), do: [key_cb_private: private]

  defp vps_fixture do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "R"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :active
    })
    |> Repo.insert!()
  end

  describe "host key verification" do
    test "the first connection pins the key it is shown", ctx do
      vps = vps_fixture()

      assert KeyCb.is_host_key(public(ctx.host), ~c"10.10.0.21", 22, :"ssh-rsa",
               key_cb_private: [vps_id: vps.id]
             )

      pinned = Repo.get!(Vps, vps.id).ssh_host_key
      assert is_binary(pinned)
      assert String.starts_with?(pinned, "SHA256:")
    end

    test "a different key on the same VPS is rejected", ctx do
      vps = vps_fixture()
      KeyCb.is_host_key(public(ctx.host), ~c"10.10.0.21", 22, :"ssh-rsa", opts(vps_id: vps.id))

      # This is the operator-MITM case, seen from inside OTP's SSH client.
      log =
        capture_log(fn ->
          refute KeyCb.is_host_key(
                   public(ctx.other),
                   ~c"10.10.0.21",
                   22,
                   :"ssh-rsa",
                   opts(vps_id: vps.id)
                 )
        end)

      assert log =~ "MISMATCH"
    end

    test "the same key again is accepted", ctx do
      vps = vps_fixture()
      key = public(ctx.host)

      assert KeyCb.is_host_key(key, ~c"10.10.0.21", 22, :"ssh-rsa", opts(vps_id: vps.id))
      assert KeyCb.is_host_key(key, ~c"10.10.0.21", 22, :"ssh-rsa", opts(vps_id: vps.id))
    end

    test "the fingerprint it computes is the one HostKeys would pin", ctx do
      vps = vps_fixture()
      key = public(ctx.host)
      fingerprint = :ssh.hostkey_fingerprint(:sha256, key) |> to_string()

      assert KeyCb.is_host_key(key, ~c"10.10.0.21", 22, :"ssh-rsa", opts(vps_id: vps.id))
      assert Repo.get!(Vps, vps.id).ssh_host_key == fingerprint
      # And the same fingerprint verifies through the other door.
      assert HostKeys.verify(vps.id, fingerprint)
    end

    test "a garbled key rejects instead of escaping into OTP", _ctx do
      vps = vps_fixture()

      # Anything raised here would surface inside OTP's SSH machinery, which was
      # not written to expect it. Rescue-and-reject fails closed.
      log =
        capture_log(fn ->
          refute KeyCb.is_host_key(
                   :not_a_key,
                   ~c"10.10.0.21",
                   22,
                   :"ssh-rsa",
                   opts(vps_id: vps.id)
                 )
        end)

      assert log =~ "rejecting"
    end

    test "no vps_id in the options accepts without pinning anything", ctx do
      # The legacy caller: pinning is hardening, not an availability dependency,
      # so a console with no pin context still connects.
      assert KeyCb.is_host_key(public(ctx.host), ~c"10.10.0.21", 22, :"ssh-rsa", opts([]))
      assert KeyCb.is_host_key(public(ctx.host), ~c"10.10.0.21", 22, :"ssh-rsa", [])
    end
  end

  describe "the client's own key" do
    test "a PEM in the options is decoded into a key OTP can use", ctx do
      pem = pem_for(ctx.console)

      assert {:ok, decoded} = KeyCb.user_key(:"ssh-rsa", opts(pem: pem))
      assert is_tuple(decoded)
    end

    test "no PEM is an error, not a crash", _ctx do
      assert KeyCb.user_key(:"ssh-rsa", opts([])) == {:error, :no_console_key}
      assert KeyCb.user_key(:"ssh-rsa", []) == {:error, :no_console_key}
      assert KeyCb.user_key(:"ssh-rsa", opts(pem: nil)) == {:error, :no_console_key}
    end

    test "something that is not a PEM is an error, not a crash", _ctx do
      for junk <- ["", "not a pem", "-----BEGIN NONSENSE-----\nzzzz\n-----END NONSENSE-----"] do
        assert KeyCb.user_key(:"ssh-rsa", opts(pem: junk)) == {:error, :no_console_key}
      end
    end
  end

  test "add_host_key is a no-op, because is_host_key is what decides" do
    # Session sets silently_accept_hosts: false, so OTP never reaches this to
    # record a key on its own; it exists to satisfy the behaviour.
    assert KeyCb.add_host_key(~c"10.10.0.21", 22, :key, []) == :ok
  end

  defp pem_for({_pub, priv}) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, priv)])
  end
end
