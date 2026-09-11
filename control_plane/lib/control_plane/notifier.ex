defmodule ControlPlane.Notifier do
  @moduledoc """
  Builds and sends every transactional email the platform emits: registration
  confirmation, password reset, and the low-balance warning sent when a
  subscription can't be charged. Delivery goes through `ControlPlane.Mailer`
  (Swoosh) — see its moduledoc for how the adapter varies per environment.

  Every message is multipart: the branded HTML body plus a plain-text
  alternative. The text part is not a formality — some clients render it by
  preference, and a mail with no text alternative scores worse with spam
  filters. Both bodies are rendered together by
  `ControlPlane.Notifier.Templates`, which returns `{text, html}` from a
  single call per email — see that module's moduledoc for why the two used
  to live apart (an inline heredoc here, a `.html.eex` there) and why that
  was a bug waiting to happen. This module no longer has any copy of its own
  to keep in sync: it asks `Templates` for both bodies and hands them to the
  mailer.

  Every `deliver_*/2` call is wrapped so a mail failure (SMTP down, misconfigured
  relay) never raises into the caller: registration, confirmation, and the
  billing settle loop must all complete regardless of whether the email actually
  went out. Failures are logged, not swallowed silently.

  ## Public API stability

  `deliver_confirmation_instructions/2`, `deliver_reset_password_instructions/2`,
  and `deliver_low_balance_warning/3` are called directly by
  `ControlPlane.Accounts` and `ControlPlane.Subscriptions`. Their names,
  arities, and `:ok | {:error, reason}` return shape are a contract with
  those callers and must not change here — only the rendering underneath
  them (this module's private `deliver/1` and `Templates`) is free to move.
  """
  require Logger

  import Swoosh.Email

  alias ControlPlane.Accounts.User
  alias ControlPlane.Mailer
  alias ControlPlane.Notifier.Templates

  @doc "Sends the 'confirm your account' email with a link carrying `token`."
  def deliver_confirmation_instructions(%User{} = user, token) do
    url = public_url() <> "/verify-email?token=" <> token
    {text, html} = Templates.confirmation(user.name, url)

    deliver(%{
      to: user.email,
      subject: "Bevestig je Bunk Hosting account",
      text: text,
      html: html
    })
  end

  @doc "Sends the password-reset email with a link carrying `token`."
  def deliver_reset_password_instructions(%User{} = user, token) do
    url = public_url() <> "/reset-password?token=" <> token
    {text, html} = Templates.reset_password(user.name, url)

    deliver(%{
      to: user.email,
      subject: "Wachtwoord opnieuw instellen — Bunk Hosting",
      text: text,
      html: html
    })
  end

  @doc """
  Sends the "we couldn't charge your wallet" warning for `vps_name`, due again on
  `retry_date`. Sent when a subscription goes `:past_due` and its VPS is stopped.
  """
  def deliver_low_balance_warning(%User{} = user, vps_name, %Date{} = retry_date) do
    top_up_url = public_url() <> "/dashboard/billing"
    # Formatted once, then handed to both bodies via Templates.low_balance/4
    # so the text and HTML mail are guaranteed to show the same date string.
    retry_date_str = Calendar.strftime(retry_date, "%d-%m-%Y")
    {text, html} = Templates.low_balance(user.name, vps_name, retry_date_str, top_up_url)

    deliver(%{
      to: user.email,
      subject: "Saldo te laag — #{vps_name} is gepauzeerd",
      text: text,
      html: html
    })
  end

  # Takes a map instead of four positional arguments: `to`/`subject`/`text`/`html`
  # are all strings, so a positional `deliver(to, subject, text, html)` reads
  # fine at the definition but is a silent transposition hazard at every call
  # site. Named keys make that class of mistake a `KeyError`/`FunctionClauseError`
  # instead of a wrong email going out.
  defp deliver(%{to: to_email, subject: subject, text: text, html: html}) do
    email =
      new()
      |> to(to_email)
      |> from({from_name(), from_email()})
      |> subject(subject)
      |> text_body(text)
      |> html_body(html)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error("mail delivery failed to #{redact(to_email)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Never let the user's own address land verbatim in Sentry/log aggregation.
  defp redact(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp from_email, do: Application.get_env(:control_plane, :mail)[:from_email]
  defp from_name, do: Application.get_env(:control_plane, :mail)[:from_name]

  # The customer-facing app origin (Next.js), not the control-plane API host.
  # PUBLIC_URL already serves this role elsewhere (e.g. mollie_controller's
  # redirect_url) because the edge proxies both the API and the app off one host.
  defp public_url, do: Application.get_env(:control_plane, :public_url) || "https://app.bunkhosting.nl"
end
