defmodule ControlPlaneWeb.OpwaarderenGrenzenTest do
  @moduledoc """
  De bedragen die `POST /api/v1/billing/topup` wel en niet accepteert, precies op
  de rand.

  `mollie_topup_test.exs` dekt het midden (EUR 25) en het duidelijk onzinnige
  (0, -100, "veel", nil). Wat daar niet in zit zijn de vier waarden waar de
  vergelijking zelf getest wordt: EUR 5,00 en EUR 4,99, EUR 1000,00 en
  EUR 1000,01. Zou `>=` ooit `>` worden, dan kan niemand meer het minimum
  opwaarderen en ziet het scherm een foutmelding bij precies het bedrag dat
  ernaast als minimum staat -- en dat merk je alleen met deze vier.

  Elke afwijzing eist bovendien dat er niets naar Mollie is gegaan. Een bedrag
  dat we zelf al afkeuren hoort de betaalprovider niet te bereiken: dat is een
  uitgaande, geauthenticeerde aanroep per verzoek, en daarmee een versterker voor
  wie hem wil misbruiken.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Mollie
  alias ControlPlane.Repo

  setup %{conn: conn} do
    email = "grens-topup-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    token = u |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), user: u}
  end

  defp mollie_accepteert do
    Req.Test.stub(Mollie, fn conn ->
      id = "tr_grens#{System.unique_integer([:positive])}"

      Req.Test.json(conn, %{
        "id" => id,
        "status" => "open",
        "_links" => %{"checkout" => %{"href" => "https://www.mollie.com/checkout/#{id}"}}
      })
    end)
  end

  defp mollie_hoort_niets do
    Req.Test.stub(Mollie, fn _conn -> raise "er ging een verzoek naar Mollie" end)
  end

  defp aanvragen(user),
    do: Repo.aggregate(from(t in TopupRequest, where: t.user_id == ^user.id), :count)

  test "precies het minimum van EUR 5,00 mag", %{conn: conn, user: u} do
    mollie_accepteert()

    assert %{"checkout_url" => url} =
             conn
             |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 500})
             |> json_response(200)

    assert url =~ "mollie.com/checkout"
    assert aanvragen(u) == 1
  end

  test "één cent onder het minimum mag niet, en bereikt Mollie niet", %{conn: conn, user: u} do
    mollie_hoort_niets()

    assert %{"error" => "invalid_amount"} =
             conn
             |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 499})
             |> json_response(422)

    assert aanvragen(u) == 0
  end

  test "precies het maximum van EUR 1000,00 mag", %{conn: conn, user: u} do
    mollie_accepteert()

    assert conn
           |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 100_000})
           |> json_response(200)

    assert aanvragen(u) == 1
  end

  test "één cent boven het maximum mag niet", %{conn: conn, user: u} do
    # De bovengrens is er niet voor ons maar voor de klant: een typefout van een
    # factor honderd bij het opwaarderen is geld dat hij eerst kwijt is en daarna
    # moet terugvragen.
    mollie_hoort_niets()

    assert conn
           |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 100_001})
           |> json_response(422)

    assert aanvragen(u) == 0
  end

  test "een bedrag als tekst telt gewoon mee", %{conn: conn, user: u} do
    # Een formulier stuurt "500" en geen 500. Zou die tak sneuvelen, dan faalt
    # elke opwaardering vanuit een gewone HTML-post met "ongeldig bedrag" terwijl
    # het bedrag klopt.
    mollie_accepteert()

    assert conn
           |> post(~p"/api/v1/billing/topup", %{"amount_cents" => "500"})
           |> json_response(200)

    assert aanvragen(u) == 1
  end

  test "een bedrag met cijfers achter de komma wordt geweigerd", %{conn: conn, user: u} do
    # Centen zijn hele getallen. "5.00" zou als 5 cent gelezen kunnen worden of
    # als 500 -- allebei fout, dus het hoort geweigerd te worden en niet geraden.
    mollie_hoort_niets()

    for bedrag <- ["500.00", "5,00", 500.5] do
      assert conn
             |> post(~p"/api/v1/billing/topup", %{"amount_cents" => bedrag})
             |> json_response(422)
    end

    assert aanvragen(u) == 0
  end
end
