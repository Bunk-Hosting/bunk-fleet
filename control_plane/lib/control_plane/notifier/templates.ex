defmodule ControlPlane.Notifier.Templates do
  @moduledoc """
  HTML bodies for the transactional emails, ported from the Bunk brand templates
  the predecessor platform used (dark card, gradient accent, Manrope/Inter).

  Each `.html.eex` under `templates/` is compiled into this module at build time,
  so a release carries no template files and does no runtime file IO.

  ## Escaping contract

  Every dynamic value is HTML-escaped HERE, at the call site, before it reaches a
  template — the templates themselves interpolate bare, already-safe strings.
  This matters because `name` is whatever the customer typed at registration: an
  unescaped `"` or `<` in it would otherwise break out of an attribute or inject
  markup into the mail body. Anything added later must go through `esc/1` too.
  """
  require EEx

  templates_dir = Path.join(__DIR__, "templates")

  for {fun, file, args} <- [
        {:layout, "layout.html.eex", [:title, :content, :year]},
        {:confirmation_body, "confirmation.html.eex", [:name, :url]},
        {:reset_password_body, "reset_password.html.eex", [:name, :url]},
        {:low_balance_body, "low_balance.html.eex", [:name, :vps_name, :retry_date, :url]}
      ] do
    path = Path.join(templates_dir, file)
    @external_resource path
    EEx.function_from_file(:defp, fun, path, args)
  end

  @doc "Full HTML document for the account-confirmation email."
  def confirmation(name, url) do
    "Bevestig je e-mailadres — Bunk Hosting"
    |> wrap(confirmation_body(greeting_name(name), esc(url)))
  end

  @doc "Full HTML document for the password-reset email."
  def reset_password(name, url) do
    "Wachtwoord resetten — Bunk Hosting"
    |> wrap(reset_password_body(greeting_name(name), esc(url)))
  end

  @doc "Full HTML document for the low-balance / VPS-paused warning."
  def low_balance(name, vps_name, retry_date, url) do
    "Saldo te laag — Bunk Hosting"
    |> wrap(low_balance_body(greeting_name(name), esc(vps_name), esc(retry_date), esc(url)))
  end

  defp wrap(title, content) do
    layout(esc(title), content, Date.utc_today().year)
  end

  # " Naam" or "" — the templates render `Hoi<%= name %>,` so an account without a
  # name still reads "Hoi," rather than "Hoi ,".
  defp greeting_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> ""
      trimmed -> " " <> esc(trimmed)
    end
  end

  defp greeting_name(_name), do: ""

  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
