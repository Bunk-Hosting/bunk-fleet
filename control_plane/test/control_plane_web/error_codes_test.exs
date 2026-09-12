defmodule ControlPlaneWeb.ErrorCodesTest do
  @moduledoc """
  The shape of the `error` field every JSON endpoint answers with.

  It is a machine code: snake_case, no spaces, no punctuation, stable across
  releases. The frontend switches on it to pick a Dutch sentence, and anything it
  does not recognise falls back to a generic message — so a code that drifts into
  a sentence does not break loudly, it just quietly stops being translated. That
  is exactly the kind of regression a test has to catch, because nobody will.

  The human-readable half goes in `detail`, which is free to be a sentence.
  """
  use ControlPlaneWeb.ConnCase, async: true

  @web_root "lib/control_plane_web"

  # `error: "..."` in a controller or plug, and `error(conn, status, "...")`
  # through the shared helper. Interpolated codes (invalid_status_#{status}) are
  # checked on their literal prefix.
  defp declared_codes do
    Path.wildcard(@web_root <> "/**/*.ex")
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      Regex.scan(~r/error: "([^"]*)"/, source, capture: :all_but_first) ++
        Regex.scan(~r/error\(conn, :[a-z_]+, "([^"]*)"/, source, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.uniq()
  end

  # The two Dutch sentences live in server-rendered HTML forms, where they are the
  # text the person reads rather than a code a client switches on.
  defp html_form_messages,
    do: ["Ongeldig e-mailadres of wachtwoord.", "Ongeldige code. Probeer opnieuw."]

  # Everything except the HTML form messages, which are the two exceptions.
  defp api_codes, do: Enum.reject(declared_codes(), &(&1 in html_form_messages()))

  test "every API error code is snake_case" do
    offenders =
      Enum.reject(api_codes(), &String.match?(&1, ~r/\A[a-z][a-z0-9_]*(#\{[a-z_]+\})?\z/))

    assert offenders == [],
           "these are sentences where a machine code belongs: #{inspect(offenders)}"
  end

  test "no error code carries punctuation or capitals" do
    offenders = Enum.filter(api_codes(), &String.match?(&1, ~r/[A-Z.,!?:;]/))

    assert offenders == [], inspect(offenders)
  end

  describe "the codes the live endpoints actually answer with" do
    test "a wrong password", %{conn: conn} do
      resp =
        conn
        |> post(~p"/api/v1/auth/login", %{"email" => "nobody@example.com", "password" => "wrong"})
        |> json_response(401)

      assert resp["error"] == "invalid_credentials"
    end

    test "a login with nothing in it", %{conn: conn} do
      resp = conn |> post(~p"/api/v1/auth/login", %{}) |> json_response(422)

      assert resp["error"] == "missing_credentials"
      # The sentence belongs in detail, where it is free to be one.
      assert is_binary(resp["detail"])
    end

    test "an unauthenticated call to an owner-scoped endpoint", %{conn: conn} do
      assert conn |> get(~p"/api/v1/vpses") |> json_response(401) |> Map.fetch!("error") ==
               "unauthorized"
    end

    test "a heartbeat with no node", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer nope")
        |> post(~p"/v1/heartbeat", %{})
        |> json_response(401)

      assert resp["error"] =~ ~r/\A[a-z][a-z0-9_]*\z/
    end
  end
end
