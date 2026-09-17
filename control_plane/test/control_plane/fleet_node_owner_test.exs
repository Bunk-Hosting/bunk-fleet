defmodule ControlPlane.FleetNodeOwnerTest do
  @moduledoc """
  Wie een node beheert.

  Tot nu toe stond dat nergens vast: een node had alleen `owner_email`, een los
  tekstveld dat als kostenplaats dient, en het enroll-token wist wel wie hem had
  gemunt maar gaf dat niet door. Zonder eigenaar betekent "alleen de eigenaar mag
  de instellingen wijzigen" dat niemand iets mag.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp gebruiker(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp fleet_node(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(
      Map.merge(
        %{name: "node-#{System.unique_integer([:positive])}", region_id: region.id},
        attrs
      )
    )
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now()
    })
    |> Repo.insert!()
  end

  describe "toewijzen" do
    test "draagt een node over aan een gebruiker" do
      u = gebruiker("eigenaar1@bunk.test")
      n = fleet_node()

      assert {:ok, bijgewerkt} = Fleet.assign_node_owner(n.id, u.id)
      assert bijgewerkt.owner_id == u.id
    end

    test "maakt een node eigenaarloos met nil" do
      # Het noodluik: raakt een eigenaar onbereikbaar, dan draag je de node over
      # in plaats van om hem heen te werken.
      u = gebruiker("eigenaar2@bunk.test")
      n = fleet_node()
      {:ok, _} = Fleet.assign_node_owner(n.id, u.id)

      assert {:ok, bijgewerkt} = Fleet.assign_node_owner(n.id, nil)
      assert is_nil(bijgewerkt.owner_id)
    end

    test "weigert een gebruiker die niet bestaat" do
      # Anders levert een typefout een node op die niemand meer kan beheren.
      n = fleet_node()

      assert {:error, :unknown_user} = Fleet.assign_node_owner(n.id, Ecto.UUID.generate())
      assert is_nil(Repo.get!(Node, n.id).owner_id)
    end

    test "weigert een node die niet bestaat" do
      u = gebruiker("eigenaar3@bunk.test")

      assert {:error, :not_found} = Fleet.assign_node_owner(Ecto.UUID.generate(), u.id)
    end
  end

  describe "mag deze gebruiker de instellingen wijzigen" do
    test "de eigenaar wel" do
      u = gebruiker("eigenaar4@bunk.test")
      n = fleet_node()
      {:ok, n} = Fleet.assign_node_owner(n.id, u.id)

      assert Fleet.node_owner?(n, u)
    end

    test "een ander niet, ook geen beheerder" do
      # Bewust: een beheerder die erbij moet draagt de node eerst aan zichzelf
      # over. Dat laat een spoor na, en een noodluik dat niemand ziet is er geen.
      eigenaar = gebruiker("eigenaar5@bunk.test")
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("beheerder@bunk.test"), :admin)
      n = fleet_node()
      {:ok, n} = Fleet.assign_node_owner(n.id, eigenaar.id)

      refute Fleet.node_owner?(n, beheerder)
    end

    test "een node zonder eigenaar is van niemand" do
      # Niet van iedereen: zonder eigenaar hoort niemand aan de instellingen te
      # kunnen komen tot een beheerder hem heeft toegewezen.
      u = gebruiker("eigenaar6@bunk.test")

      refute Fleet.node_owner?(fleet_node(), u)
    end

    test "niet ingelogd is nooit de eigenaar" do
      n = fleet_node()
      {:ok, n} = Fleet.assign_node_owner(n.id, gebruiker("eigenaar7@bunk.test").id)

      refute Fleet.node_owner?(n, nil)
    end
  end
end
