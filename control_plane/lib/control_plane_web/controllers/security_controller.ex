defmodule ControlPlaneWeb.SecurityController do
  @moduledoc """
  Where browsers report Content-Security-Policy violations.

  The policy has carried a `report-uri` since it was written, pointing at a path
  that did not exist — so every violation a browser tried to report got a 404 and
  the reporting was decoration. A CSP you never hear from is a CSP you cannot
  tell is working: violations are how you learn that the policy is too tight for
  a legitimate feature, or that someone is trying to inject a script.

  Deliberately unauthenticated. Browsers send these with no credentials, and
  refusing them would bring back the silence this endpoint exists to end. It is
  rate-limited instead, because an endpoint anyone can POST to is an endpoint
  anyone can flood.
  """
  use ControlPlaneWeb, :controller

  require Logger

  # Enough to identify the violation, bounded so a report cannot become a log
  # flood on its own.
  @max_field 300

  def csp_report(conn, params) do
    report = params["csp-report"] || params

    Logger.warning(
      "csp violation: " <>
        "directive=#{field(report, "violated-directive")} " <>
        "blocked=#{field(report, "blocked-uri")} " <>
        "document=#{field(report, "document-uri")}"
    )

    # 204 whatever the body was. A browser has nothing useful to do with an error
    # here, and telling a prober which shapes we parse is free information.
    send_resp(conn, :no_content, "")
  end

  defp field(report, key) when is_map(report) do
    case Map.get(report, key) do
      value when is_binary(value) -> value |> String.slice(0, @max_field) |> sanitise()
      _ -> "-"
    end
  end

  defp field(_report, _key), do: "-"

  # The report is attacker-controlled text on its way into a log line. Newlines
  # would let it forge log entries of its own.
  defp sanitise(value), do: String.replace(value, ~r/[[:cntrl:]]/, "")
end
