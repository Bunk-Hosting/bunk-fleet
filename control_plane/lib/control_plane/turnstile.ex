defmodule ControlPlane.Turnstile do
  @moduledoc """
  Server-side verification of Cloudflare Turnstile (CAPTCHA) tokens.

  The frontend renders the widget and sends its token; without a *server-side*
  check a bot can simply call the JSON API directly and skip the widget entirely
  (which is what enables signup-bonus farming / credential stuffing). `verify/2`
  closes that by POSTing the token to Cloudflare's siteverify.

  Config-gated: when `:control_plane, :turnstile, :secret_key` is set (env
  `TURNSTILE_SECRET_KEY`), verification is enforced — a missing/invalid/unverifiable
  token is rejected. When no secret is configured, verification is skipped so the
  platform still runs; **set `TURNSTILE_SECRET_KEY` in prod to activate it.**
  """
  require Logger

  @endpoint "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  @doc "True when a secret key is configured (verification enforced)."
  def enabled?, do: is_binary(secret()) and secret() != ""

  @doc """
  Returns `:ok` when the token is valid (or verification is disabled), else
  `{:error, :captcha_required | :captcha_failed | :captcha_unavailable}`.
  Fails closed when enabled: a verification outage rejects rather than admits.
  """
  def verify(token, remote_ip \\ nil) do
    cond do
      not enabled?() ->
        :ok

      not (is_binary(token) and token != "") ->
        {:error, :captcha_required}

      true ->
        do_verify(token, remote_ip)
    end
  end

  defp do_verify(token, remote_ip) do
    form = %{secret: secret(), response: token} |> put_ip(remote_ip)

    case Req.post(@endpoint, form: form, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        :ok

      {:ok, %{body: body}} ->
        Logger.warning(
          "turnstile verify rejected: #{inspect(is_map(body) && body["error-codes"])}"
        )

        {:error, :captcha_failed}

      {:error, reason} ->
        Logger.warning("turnstile verify unavailable: #{inspect(reason)}")
        {:error, :captcha_unavailable}
    end
  end

  defp put_ip(form, ip) when is_binary(ip) and ip != "", do: Map.put(form, :remoteip, ip)
  defp put_ip(form, _), do: form

  defp secret, do: Application.get_env(:control_plane, :turnstile, [])[:secret_key]
end
