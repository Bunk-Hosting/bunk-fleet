defmodule ControlPlane.Notifier do
  @moduledoc """
  Builds and sends every transactional email the platform emits: registration
  confirmation, password reset, and the low-balance warning sent when a
  subscription can't be charged. Delivery goes through `ControlPlane.Mailer`
  (Swoosh) — see its moduledoc for how the adapter varies per environment.

  Every message is multipart: the branded HTML body from
  `ControlPlane.Notifier.Templates` plus a plain-text alternative. The text part
  is not a formality — some clients render it by preference, and a mail with no
  text alternative scores worse with spam filters.

  Every `deliver_*/2` call is wrapped so a mail failure (SMTP down, misconfigured
  relay) never raises into the caller: registration, confirmation, and the
  billing settle loop must all complete regardless of whether the email actually
  went out. Failures are logged, not swallowed silently.
  """
  require Logger

  import Swoosh.Email

  alias ControlPlane.Accounts.User
  alias ControlPlane.Mailer
  alias ControlPlane.Notifier.Templates

  @doc "Sends the 'confirm your account' email with a link carrying `token`."
  def deliver_confirmation_instructions(%User{} = user, token) do
    url = public_url() <> "/verify-email?token=" <> token

    deliver(
      user.email,
      "Bevestig je Bunk Hosting account",
      """
      Hoi#{name_suffix(user)},

      Bevestig je e-mailadres om je Bunk Hosting account te activeren en je
      welkomstkrediet te ontvangen:

      #{url}

      Deze link is 24 uur geldig. Heb je geen account aangemaakt? Dan kun je deze e-mail negeren.
      """,
      Templates.confirmation(user.name, url)
    )
  end

  @doc "Sends the password-reset email with a link carrying `token`."
  def deliver_reset_password_instructions(%User{} = user, token) do
    url = public_url() <> "/reset-password?token=" <> token

    deliver(
      user.email,
      "Wachtwoord opnieuw instellen — Bunk Hosting",
      """
      Hoi#{name_suffix(user)},

      Je hebt een nieuw wachtwoord aangevraagd voor je Bunk Hosting account. Klik op
      onderstaande link om een nieuw wachtwoord in te stellen:

      #{url}

      Deze link is 1 uur geldig. Heb je dit niet aangevraagd? Dan kun je deze e-mail
      negeren — je wachtwoord blijft ongewijzigd.
      """,
      Templates.reset_password(user.name, url)
    )
  end

  @doc """
  Sends the "we couldn't charge your wallet" warning for `vps_name`, due again on
  `retry_date`. Sent when a subscription goes `:past_due` and its VPS is stopped.
  """
  def deliver_low_balance_warning(%User{} = user, vps_name, %Date{} = retry_date) do
    top_up_url = public_url() <> "/dashboard/billing"

    deliver(
      user.email,
      "Saldo te laag — #{vps_name} is gepauzeerd",
      """
      Hoi#{name_suffix(user)},

      We konden de maandelijkse kosten voor je VPS "#{vps_name}" niet afschrijven
      omdat je Bunk-wallet saldo te laag is. Om dataverlies te voorkomen hebben we
      de VPS gepauzeerd — er draait niets meer op, maar niets is verwijderd.

      Waardeer je wallet op vóór #{Calendar.strftime(retry_date, "%d-%m-%Y")} en we
      proberen het automatisch opnieuw en zetten de VPS weer aan:

      #{top_up_url}

      Blijft het saldo te laag, dan blijft de VPS gepauzeerd totdat je opwaardeert —
      er wordt niets verwijderd.
      """,
      Templates.low_balance(
        user.name,
        vps_name,
        Calendar.strftime(retry_date, "%d-%m-%Y"),
        top_up_url
      )
    )
  end

  defp deliver(to_email, subject, body_text, body_html) do
    email =
      new()
      |> to(to_email)
      |> from({from_name(), from_email()})
      |> subject(subject)
      |> text_body(body_text)
      |> html_body(body_html)

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

  defp name_suffix(%User{name: name}) when is_binary(name) and name != "", do: " " <> name
  defp name_suffix(_user), do: ""

  defp from_email, do: Application.get_env(:control_plane, :mail)[:from_email]
  defp from_name, do: Application.get_env(:control_plane, :mail)[:from_name]

  # The customer-facing app origin (Next.js), not the control-plane API host.
  # PUBLIC_URL already serves this role elsewhere (e.g. mollie_controller's
  # redirect_url) because the edge proxies both the API and the app off one host.
  defp public_url, do: Application.get_env(:control_plane, :public_url) || "https://app.bunkhosting.nl"
end
