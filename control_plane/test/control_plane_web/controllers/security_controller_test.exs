defmodule ControlPlaneWeb.SecurityControllerTest do
  use ControlPlaneWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @report %{
    "csp-report" => %{
      "document-uri" => "https://app.bunkhosting.nl/dashboard",
      "violated-directive" => "script-src",
      "blocked-uri" => "https://evil.example/x.js"
    }
  }

  test "a browser can post a violation without credentials", %{conn: conn} do
    # Browsers send these with no credentials. Requiring auth would bring back
    # the silence the endpoint exists to end.
    assert conn |> post(~p"/api/v1/security/csp-report", @report) |> response(204)
  end

  test "the violation is logged with what it was" do
    log =
      capture_log(fn ->
        build_conn() |> post(~p"/api/v1/security/csp-report", @report) |> response(204)
      end)

    assert log =~ "csp violation"
    assert log =~ "script-src"
    assert log =~ "evil.example"
  end

  test "a report cannot forge log lines of its own" do
    # The report is attacker-controlled text on its way into a log line.
    forged = %{
      "csp-report" => %{
        "violated-directive" => "script-src\n2026-01-01 [error] alles is in orde",
        "blocked-uri" => "x",
        "document-uri" => "y"
      }
    }

    log = capture_log(fn -> build_conn() |> post(~p"/api/v1/security/csp-report", forged) end)

    refute log =~ "alles is in orde\n"
    assert log =~ "alles is in orde"
  end

  test "a report sent as application/csp-report is actually parsed" do
    # Browsers use this content type for `report-uri`, never application/json.
    # Without the rewriting plug the body arrives unparsed and every field logs
    # as empty — which looks exactly like a working endpoint.
    log =
      capture_log(fn ->
        build_conn()
        |> put_req_header("content-type", "application/csp-report")
        |> post(~p"/api/v1/security/csp-report", Jason.encode!(@report))
        |> response(204)
      end)

    assert log =~ "script-src"
    assert log =~ "evil.example"
  end

  test "a report sent as application/reports+json is parsed too" do
    # The Reporting API's content type. Plug's JSON parser matches
    # application/*+json already, so this needs nothing — the test is here so it
    # stays true.
    log =
      capture_log(fn ->
        build_conn()
        |> put_req_header("content-type", "application/reports+json")
        |> post(~p"/api/v1/security/csp-report", Jason.encode!(@report))
        |> response(204)
      end)

    assert log =~ "script-src"
  end

  test "the rewriting is scoped to the report path" do
    # A request to any other route keeps whatever content type it claimed.
    assert build_conn()
           |> put_req_header("content-type", "application/csp-report")
           |> get(~p"/api/v1/auth/me")
           |> json_response(401)
  end

  test "a report with nothing useful in it is still accepted" do
    # An empty or oddly-shaped body is a browser quirk, not an attack, and a
    # browser has nothing useful to do with an error here.
    for body <- [%{}, %{"csp-report" => %{}}, %{"csp-report" => "not-an-object"}] do
      assert build_conn() |> post(~p"/api/v1/security/csp-report", body) |> response(204)
    end
  end

  test "an enormous field cannot become a log flood" do
    huge = String.duplicate("a", 10_000)

    log =
      capture_log(fn ->
        build_conn()
        |> post(~p"/api/v1/security/csp-report", %{"csp-report" => %{"blocked-uri" => huge}})
      end)

    refute log =~ String.duplicate("a", 1_000)
  end
end
