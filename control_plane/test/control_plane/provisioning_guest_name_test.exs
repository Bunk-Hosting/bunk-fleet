defmodule ControlPlane.ProvisioningGuestNameTest do
  @moduledoc """
  De naam waaronder een gast op de hypervisor komt te staan.

  De agent herkent hieraan of hij een machine al heeft aangemaakt. Stond daar
  ooit alleen de door de klant gekozen naam in, dan nam de tweede klant met
  dezelfde naam op een node de draaiende VM van de eerste over — de kritieke
  bevinding van juli. Het patroon dat een eigenaar in het dashboard zet mag dat
  niet opnieuw mogelijk maken, dus deze tests gaan over uniciteit, niet over
  cosmetiek.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()
  end

  defp fleet_node(region, patroon) do
    %Node{}
    |> Node.changeset(%{name: "pve-eindhoven", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      guest_name_pattern: patroon,
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000,
      reported_avail_vcpu: 32,
      reported_avail_ram_mb: 65_536,
      reported_avail_disk_gb: 1000
    })
    |> Repo.insert!()
  end

  # De naam zoals hij in de provision-opdracht terechtkomt.
  defp gastnaam(patroon, vps_naam) do
    region = regio()
    _node = fleet_node(region, patroon)

    {:ok, %{command: %Command{payload: payload}}} =
      Provisioning.create_vps(%{
        name: vps_naam,
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        owner_email: "klaas@voorbeeld.nl"
      })

    payload["name"]
  end

  test "zonder patroon is het de naam plus het unieke deel" do
    naam = gastnaam(nil, "Webserver Productie")

    assert naam =~ ~r/^webserver-productie-[0-9a-f]{8}$/
  end

  test "een patroon wordt toegepast" do
    naam = gastnaam("bunk-{klant}-{id}", "Webserver")

    assert naam =~ ~r/^bunk-klaas-[0-9a-f]{8}$/
  end

  test "{node} wordt de naam van de machine waar hij op landt" do
    naam = gastnaam("{node}-{id}", "Webserver")

    assert naam =~ ~r/^pve-eindhoven-[0-9a-f]{8}$/
  end

  test "twee VPS'en met dezelfde klantnaam krijgen verschillende gastnamen" do
    # Dit is de kern. Zonder het unieke deel zou de agent de tweede aanzien voor
    # de eerste en zijn draaiende machine overnemen.
    region = regio()
    _node = fleet_node(region, "{naam}-{id}")

    namen =
      for _ <- 1..2 do
        {:ok, %{command: %Command{payload: payload}}} =
          Provisioning.create_vps(%{
            name: "Zelfde Naam",
            region_id: region.id,
            vcpu: 1,
            ram_mb: 1024,
            disk_gb: 20
          })

        payload["name"]
      end

    assert length(Enum.uniq(namen)) == 2
  end

  test "een gastnaam blijft binnen wat een hypervisor accepteert" do
    # Te lang of met rare tekens wordt door Proxmox geweigerd, en dat zou pas bij
    # het uitrollen blijken.
    naam = gastnaam("{naam}-{id}", String.duplicate("heel-lange-naam-", 6))

    assert String.length(naam) <= 63
    assert naam =~ ~r/^[a-z0-9-]+$/
  end
end
