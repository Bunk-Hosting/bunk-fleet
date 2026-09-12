defmodule ControlPlaneWeb.Plugs.CspReportContentType do
  @moduledoc """
  Lets the JSON parser see a CSP violation report.

  Browsers post these as `application/csp-report` (the `report-uri` directive) or
  `application/reports+json` (the Reporting API), never as `application/json`.
  Plug's JSON parser matches `application/json` and `application/*+json`, so the
  first of those arrives unparsed — and an unparsed body means the report
  endpoint logs a violation with every field empty, which looks exactly like a
  working endpoint.

  Rewriting the header for one known path is narrower than widening the parser
  for the whole API: nothing else changes, and a request to any other route is
  untouched whatever it claims to be.
  """
  @behaviour Plug

  @path "/api/v1/security/csp-report"
  @rewritten ["application/csp-report"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: @path} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [type | _] ->
        if String.starts_with?(type, @rewritten),
          do: %{conn | req_headers: put_content_type(conn.req_headers)},
          else: conn

      [] ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp put_content_type(headers) do
    Enum.map(headers, fn
      {"content-type", _} -> {"content-type", "application/json"}
      header -> header
    end)
  end
end
