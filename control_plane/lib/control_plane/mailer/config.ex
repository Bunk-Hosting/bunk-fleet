defmodule ControlPlane.Mailer.Config do
  @moduledoc """
  Builds the Swoosh SMTP adapter options for `ControlPlane.Mailer`.

  This lives in a module instead of inline in `config/runtime.exs` because the
  rules below are subtle enough to deserve tests, and config files can only be
  exercised by booting a release with exactly the right environment — a terrible
  feedback loop for logic whose failure mode is a hung connection or an opaque
  TLS handshake error on the first password-reset mail of the day.

  `smtp_options/1` is the pure core: it takes the environment as data and
  returns the keyword list, so every branch is reachable from ExUnit without
  touching the real OS environment. `smtp_options_from_system_env/0` is the thin
  `System.get_env/1` wrapper that `config/runtime.exs` calls.

  Everything here must stay callable during release boot, i.e. *before any
  application is started*: no processes, no `Application.get_env/2`, and the one
  dependency it does touch (`CAStore`) is only asked for a file path, guarded so
  it can never take the boot down (see `cacertfile/1`).
  """

  # STARTTLS submission is the sane default for a relay that does not tell us
  # which port it wants.
  @default_port "587"

  # The one port on which SMTP is implicitly wrapped in TLS rather than upgraded.
  @implicit_ssl_port 465

  @fallback_cacertfile "/etc/ssl/certs/ca-certificates.crt"

  @env_keys ~w(SMTP_HOST SMTP_PORT SMTP_SSL SMTP_USERNAME SMTP_PASSWORD SMTP_CACERTFILE)

  @doc """
  Reads the `SMTP_*` variables from the OS environment and builds the adapter
  options. Impure by definition — this is the only part that knows about
  `System.get_env/1`, so the interesting logic stays testable.
  """
  def smtp_options_from_system_env do
    @env_keys
    |> Map.new(fn key -> {key, System.get_env(key)} end)
    |> smtp_options()
  end

  @doc """
  Builds the `ControlPlane.Mailer` adapter options from an environment map.

  `env` maps env-var names to their values (`%{"SMTP_HOST" => "smtp.example.com",
  "SMTP_PORT" => "465"}`); a keyword list of the same names works too. `nil`
  values count as unset, which is what makes a `System.get_env/1`-built map
  behave identically to one that simply omits the key. `SMTP_HOST` is required —
  the caller is expected to have checked it before deciding to configure SMTP at
  all.

  Two things here are not obvious and were paid for in downtime:

    * **The TLS mode is derived from the port.** 465 is implicit SSL (the socket
      is encrypted before the SMTP conversation starts), 587 connects in the
      clear and upgrades via STARTTLS. Sending 465 traffic with the 587 settings
      just hangs, so this is derived rather than left to a default that silently
      fits only one of them. `SMTP_SSL` overrides for relays that disagree.

    * **The CA options live under a different key per mode**, and gen_smtp
      silently ignores the wrong one — verified against the live relay, not
      inferred. Implicit SSL reads them from `:sockopts`, a STARTTLS upgrade from
      `:tls_options`. It is either/or, never both: in the STARTTLS case
      `:sockopts` is handed to a plain `gen_tcp` connect, where SSL options are
      an error.

  ## Example

      opts = ControlPlane.Mailer.Config.smtp_options(%{"SMTP_HOST" => "smtp.example.com"})
      {opts[:port], opts[:ssl], opts[:tls]} == {587, false, :always}
  """
  def smtp_options(env) when is_map(env) or is_list(env) do
    env = normalize_env(env)

    host =
      env["SMTP_HOST"] ||
        raise(ArgumentError, "SMTP_HOST must be set to build SMTP mailer options")

    port = String.to_integer(env["SMTP_PORT"] || @default_port)

    ca_opts = [
      verify: :verify_peer,
      cacertfile: cacertfile(env["SMTP_CACERTFILE"]),
      depth: 4,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [
      adapter: Swoosh.Adapters.SMTP,
      relay: host,
      port: port,
      username: env["SMTP_USERNAME"],
      password: env["SMTP_PASSWORD"],
      # Fail loudly on a rejected credential instead of silently sending
      # unauthenticated (which every relay worth using would then bounce).
      auth: :always,
      retries: 2
    ] ++ tls_config(implicit_ssl?(env["SMTP_SSL"], port), ca_opts)
  end

  @doc """
  Resolves the CA bundle used to verify the relay's certificate.

  Erlang's `:ssl` does NOT read the OS trust store the way Python or curl do,
  while gen_smtp defaults to `verify_peer` — so with no explicit bundle every
  send dies with `{:options, :incompatible, [verify: :verify_peer, cacerts:
  :undefined]}`. An explicit `SMTP_CACERTFILE` wins; otherwise castore's pinned
  bundle beats whatever the base image happens to ship, with the OS store as a
  last resort.

  The `try/rescue` is load-bearing: this runs during config evaluation, where an
  exception takes down the entire boot. A missing or broken castore is a reason
  to fall back, never a reason for the node not to start.
  """
  def cacertfile(nil) do
    try do
      CAStore.file_path()
    rescue
      _ -> @fallback_cacertfile
    end
  end

  def cacertfile(path) when is_binary(path), do: path

  # "1"/"true" force implicit SSL, "0"/"false" force plain-with-STARTTLS, and
  # anything else (including an unset variable) falls back to the port.
  defp implicit_ssl?(flag, _port) when flag in ["1", "true"], do: true
  defp implicit_ssl?(flag, _port) when flag in ["0", "false"], do: false
  defp implicit_ssl?(_flag, port), do: port == @implicit_ssl_port

  defp tls_config(true, ca_opts), do: [ssl: true, tls: :never, sockopts: ca_opts]
  defp tls_config(false, ca_opts), do: [ssl: false, tls: :always, tls_options: ca_opts]

  # Accepts a map or keyword list keyed by env-var name, and drops `nil` values
  # so "set to nil" and "absent" are the same thing — `System.get_env/1` returns
  # the former, a hand-written test map the latter.
  defp normalize_env(env) do
    Enum.reduce(env, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end
end
