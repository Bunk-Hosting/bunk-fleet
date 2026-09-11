defmodule ControlPlaneWeb.Plugs.AdminAuth do
  @moduledoc """
  Authenticates operator/admin API requests by a single shared-secret admin token,
  supplied as an `Authorization: Bearer <admin_token>` header.

  The expected token is read from `Application.get_env(:control_plane, :admin_token)`
  (which falls back to the `ADMIN_TOKEN` environment variable in config). If no admin
  token is configured (nil or empty), ALL requests are denied with `401` — the admin
  API is closed by default rather than open.

  On any failure (missing/malformed header, unconfigured token or mismatch) the
  connection is halted with a `401` JSON body `{"error": "unauthorized"}`. The
  comparison is constant-time via `Plug.Crypto.secure_compare/2`.
  """
  alias ControlPlaneWeb.Plugs.Bearer

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, expected} <- configured_token(),
         {:ok, presented} <- Bearer.token(conn),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ -> Bearer.unauthorized(conn)
    end
  end

  defp configured_token do
    case Application.get_env(:control_plane, :admin_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end
end
