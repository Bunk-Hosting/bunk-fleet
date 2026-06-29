defmodule ControlPlane.Console.KeyCb do
  @moduledoc """
  `:ssh_client_key_api` callback for the browser console's SSH client. It hands
  OTP the platform console private key (a PEM passed via `key_cb_private`) for
  publickey auth, and enforces trust-on-first-use pinning of each VPS's host key
  (via `Console.HostKeys`, threaded the `vps_id` through `key_cb_private`).
  """
  @behaviour :ssh_client_key_api
  require Logger

  alias ControlPlane.Console.HostKeys

  @impl true
  # Only reached if a key were ever silently accepted; the Session sets
  # `silently_accept_hosts: false`, so `is_host_key/5` below is authoritative and
  # this is a no-op kept to satisfy the behaviour.
  def add_host_key(_host, _port, _public_host_key, _opts), do: :ok

  @impl true
  def is_host_key(key, _host, _port, _algorithm, opts) do
    vps_id = private(opts)[:vps_id]
    fingerprint = key |> hostkey_fingerprint() |> to_string()
    HostKeys.verify(vps_id, fingerprint)
  rescue
    e ->
      Logger.error("console: host-key verification raised: #{inspect(e)} — rejecting")
      false
  end

  @impl true
  def user_key(_algorithm, opts) do
    pem = Keyword.get(private(opts), :pem)

    with pem when is_binary(pem) <- pem,
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      _ -> {:error, :no_console_key}
    end
  end

  defp private(opts), do: :proplists.get_value(:key_cb_private, opts, [])

  defp hostkey_fingerprint(key), do: :ssh.hostkey_fingerprint(:sha256, key)
end
