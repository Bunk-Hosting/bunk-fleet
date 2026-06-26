defmodule ControlPlane.Console.KeyCb do
  @moduledoc """
  `:ssh_client_key_api` callback that hands the platform console private key (a
  PEM passed via `key_cb_private`) to OTP's SSH client for publickey auth. Host
  keys are accepted (the connection is to our own VPSes over a trusted overlay).
  """
  @behaviour :ssh_client_key_api

  @impl true
  def add_host_key(_host, _port, _public_host_key, _opts), do: :ok

  @impl true
  def is_host_key(_key, _host, _port, _algorithm, _opts), do: true

  @impl true
  def user_key(_algorithm, opts) do
    cb = :proplists.get_value(:key_cb_private, opts, [])
    pem = Keyword.get(cb, :pem)

    with pem when is_binary(pem) <- pem,
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      _ -> {:error, :no_console_key}
    end
  end
end
