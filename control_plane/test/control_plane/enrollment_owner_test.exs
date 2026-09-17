defmodule ControlPlane.EnrollmentOwnerTest do
  @moduledoc """
  Wie de eigenaar van een node wordt bij het inschrijven.

  De installer vraagt erom, omdat degene die de machine neerzet zichzelf als
  beheerder hoort op te geven in plaats van dat het afhangt van wie het token
  toevallig heeft gemunt. Maar wie een token in handen heeft mag daarmee niet
  bepalen wie een node bezit als het token dat al zegt.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp gebruiker(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()
  end

  defp token(attrs \\ %{}) do
    {:ok, {plaintext, _}} =
      Enrollment.create_enroll_token(
        Map.merge(%{region_id: regio().id, ttl_seconds: 3600}, attrs)
      )

    plaintext
  end

  defp schrijf_in(plaintext, extra) do
    {:ok, %{node: node}} =
      Enrollment.enroll(plaintext, Map.merge(%{hypervisor: "proxmox"}, extra))

    node
  end

  test "het opgegeven adres wordt de eigenaar als het token er geen heeft" do
    # Het normale geval: een beheerder maakt een token en laat iemand anders de
    # machine neerzetten.
    u = gebruiker("operator1@bunk.test")

    node = schrijf_in(token(), %{owner_email: "operator1@bunk.test"})

    assert node.owner_id == u.id
    assert node.owner_email == "operator1@bunk.test"
  end

  test "het token wint van het opgegeven adres" do
    # Wie een token in handen krijgt hoort niet te kunnen bepalen wie de node
    # bezit door een ander adres in te typen.
    eigenaar = gebruiker("eigenaar@bunk.test")
    _ander = gebruiker("ander@bunk.test")

    node =
      token(%{owner_id: eigenaar.id, owner_email: "eigenaar@bunk.test"})
      |> schrijf_in(%{owner_email: "ander@bunk.test"})

    assert node.owner_id == eigenaar.id
  end

  test "een adres zonder account levert geen eigenaar op, maar wordt wel bewaard" do
    # Zo ziet een beheerder in het paneel wie het zou moeten zijn en kan hij de
    # node toewijzen zodra dat account bestaat, in plaats van dat de invoer stil
    # verdwijnt.
    node = schrijf_in(token(), %{owner_email: "bestaatniet@bunk.test"})

    assert is_nil(node.owner_id)
    assert node.owner_email == "bestaatniet@bunk.test"
  end

  test "een leeg of ontbrekend adres verandert niets" do
    for extra <- [%{}, %{owner_email: ""}, %{owner_email: "   "}] do
      node = schrijf_in(token(), extra)
      assert is_nil(node.owner_id)
    end
  end

  test "spaties rond het adres tellen niet mee" do
    u = gebruiker("operator2@bunk.test")

    node = schrijf_in(token(), %{owner_email: "  operator2@bunk.test  "})

    assert node.owner_id == u.id
  end
end
