defmodule ControlPlane.Notifier.Templates do
  @moduledoc """
  Renders both bodies — plain text and branded HTML — for every transactional
  email the platform sends.

  ## Why one module renders both formats

  Historically the HTML body lived here as a compiled `.html.eex` template
  while the plain-text alternative lived as an inline heredoc back in
  `ControlPlane.Notifier`. That split is a bug generator: the two copies of
  the same customer-facing copy (URL, expiry wording, VPS name) inevitably
  drift, and nothing catches the drift because they're tested (if at all)
  independently. Putting a `.txt.eex` next to every `.html.eex` and having a
  single function hand back `{text, html}` makes "these two must say the same
  thing" a property of the code layout instead of a discipline someone has to
  remember.

  Each `.html.eex` / `.txt.eex` pair under `templates/` is compiled into this
  module at build time via `EEx.function_from_file/4`, so a release carries no
  template files and does no runtime file IO. The `.html.eex` files are a
  pixel-identical port of the previous platform's brand templates (dark card,
  gradient accent, Manrope/Inter) and must not be edited casually — a
  visual diff against the old platform is the only way to confirm they still
  match.

  ## Escaping contract

  `name` (and `vps_name`) come straight from customer input — whatever a
  customer typed at registration, or named their VPS. An unescaped `"` or `<`
  in that value would break out of an HTML attribute or inject markup into
  the mail body, so **every** dynamic value that flows into an HTML template
  is escaped via `esc/1` before it reaches the template — the `.html.eex`
  files themselves just interpolate bare, already-safe strings.

  The plain-text templates get the *unescaped* raw value instead. This is
  deliberate, not an oversight: plain text has no markup to inject, and
  running the same HTML-escaping over it would leave literal `&amp;`/`&quot;`
  garbage in a mail client that renders text verbatim. Concretely, the
  argument named `name` (etc.) passed to an HTML template function
  (`confirmation_body/2` and friends) is never the same string as the `name`
  passed to the text counterpart (`confirmation_text/2` and friends) — see
  `greeting_name/2`, which is the one place that decides, per format, whether
  to escape.

  Anything added to these emails later must follow the same rule: escape
  before the HTML template, never before the text template.
  """
  require EEx

  templates_dir = Path.join(__DIR__, "templates")

  # HTML bodies. Every argument arriving here is already escaped by the
  # public functions below — these templates only interpolate safe strings.
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

  # Plain-text bodies — the ported heredocs from ControlPlane.Notifier, now
  # living next to the HTML they must stay in sync with. These receive raw,
  # unescaped values on purpose (see the escaping contract above).
  for {fun, file, args} <- [
        {:confirmation_text, "confirmation.txt.eex", [:name, :url]},
        {:reset_password_text, "reset_password.txt.eex", [:name, :url]},
        {:low_balance_text, "low_balance.txt.eex", [:name, :vps_name, :retry_date, :url]}
      ] do
    path = Path.join(templates_dir, file)
    @external_resource path
    EEx.function_from_file(:defp, fun, path, args)
  end

  @doc """
  Renders the account-confirmation email.

  Returns `{text, html}` so a caller (see `ControlPlane.Notifier`) always
  gets both parts of the multipart message from a single call, with no way
  to accidentally send one format without the other.
  """
  @spec confirmation(name :: String.t() | nil, url :: String.t()) ::
          {String.t(), String.t()}
  def confirmation(name, url) do
    text = confirmation_text(greeting_name(name, :text), url)

    html =
      wrap(
        "Bevestig je e-mailadres — Bunk Hosting",
        confirmation_body(greeting_name(name, :html), esc(url))
      )

    {text, html}
  end

  @doc "Renders the password-reset email. Returns `{text, html}` — see `confirmation/2`."
  @spec reset_password(name :: String.t() | nil, url :: String.t()) ::
          {String.t(), String.t()}
  def reset_password(name, url) do
    text = reset_password_text(greeting_name(name, :text), url)

    html =
      wrap(
        "Wachtwoord resetten — Bunk Hosting",
        reset_password_body(greeting_name(name, :html), esc(url))
      )

    {text, html}
  end

  @doc """
  Renders the low-balance / VPS-paused warning email. Returns `{text, html}` —
  see `confirmation/2`.

  `retry_date` is expected pre-formatted (e.g. `"11-09-2026"`) rather than a
  `%Date{}`: formatting is the caller's job, done once, so the same string
  lands in both the text and HTML variant instead of being computed twice.
  """
  @spec low_balance(
          name :: String.t() | nil,
          vps_name :: String.t(),
          retry_date :: String.t(),
          url :: String.t()
        ) :: {String.t(), String.t()}
  def low_balance(name, vps_name, retry_date, url) do
    text = low_balance_text(greeting_name(name, :text), vps_name, retry_date, url)

    html =
      wrap(
        "Saldo te laag — Bunk Hosting",
        low_balance_body(greeting_name(name, :html), esc(vps_name), esc(retry_date), esc(url))
      )

    {text, html}
  end

  defp wrap(title, content) do
    layout(esc(title), content, Date.utc_today().year)
  end

  # The single source of "Hoi<greeting>," fallback logic, shared by every
  # text and HTML template above. This used to be duplicated: once here as
  # `greeting_name/1` (HTML-escaped) and once in ControlPlane.Notifier as
  # `name_suffix/1` (unescaped, for the heredocs that lived there). Both
  # computed the exact same "" vs " Naam" fork, just for different formats —
  # a classic case of the same rule drifting apart in two places. Now there's
  # one function, parameterized by format, so an account without a name still
  # reads "Hoi," (not "Hoi ,") in both the text and HTML mail.
  defp greeting_name(name, format) when is_binary(name) do
    case String.trim(name) do
      "" -> ""
      trimmed when format == :html -> " " <> esc(trimmed)
      trimmed -> " " <> trimmed
    end
  end

  defp greeting_name(_name, _format), do: ""

  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
