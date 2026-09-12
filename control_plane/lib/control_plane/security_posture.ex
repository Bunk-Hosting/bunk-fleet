defmodule ControlPlane.SecurityPosture do
  @moduledoc """
  Says out loud, at boot, which optional protections are switched off.

  Several defences here are config-gated so the platform still starts without
  them: no Turnstile secret means signup verification is skipped, no ops address
  means operational alerts go nowhere. Each of those is a deliberate escape
  hatch, and each of them fails open — the request succeeds, the alert is simply
  not sent, and nothing in the logs says so.

  A protection that is off and silent is worse than one that was never built: the
  dashboard shows a CAPTCHA widget, the runbook says alerts are wired up, and
  both are true right up until someone looks. This module makes the gap a line in
  the log every time the control plane starts.

  It only reports. Turning a protection on is a deployment decision (a secret has
  to exist first), so nothing here refuses to boot.
  """
  require Logger

  alias ControlPlane.Notifier
  alias ControlPlane.Turnstile

  @doc """
  Logs one warning per inactive protection. Returns the list of their keys, so a
  test can assert on what was found rather than on log output.
  """
  def report do
    inactive =
      Enum.reject(checks(), fn {_key, active?, _message} -> active?.() end)

    for {_key, _active?, message} <- inactive do
      Logger.warning("security posture: " <> message)
    end

    Enum.map(inactive, fn {key, _active?, _message} -> key end)
  end

  defp checks do
    [
      {:turnstile, &Turnstile.enabled?/0,
       "TURNSTILE_SECRET_KEY is not set, so registration is NOT bot-verified. " <>
         "The only things standing between a script and the signup bonus are the " <>
         "per-IP rate limit and email confirmation."},
      {:ops_email, &Notifier.ops_email_configured?/0,
       "OPS_EMAIL is not set, so operational alerts (a charged VPS that was never " <>
         "created, a backup that stopped running) are written to the log and to nobody."},
      {:mollie, &mollie_configured?/0,
       "MOLLIE_API_KEY is not set, so customers cannot top up their wallet."}
    ]
  end

  defp mollie_configured?, do: ControlPlane.Mollie.configured?()
end
