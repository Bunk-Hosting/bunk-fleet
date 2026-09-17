defmodule ControlPlane.ProvisioningConsoleKeyTest do
  @moduledoc """
  Welke publieke sleutel er in de `authorized_keys` van een nieuwe VPS belandt.

  Dit is het stuk dat het verschil maakt. De sleutel wordt bij het uitrollen via
  cloud-init in de machine gezet en daarna nooit meer; staat de gedeelde
  platformsleutel er alsnog naast, dan is het per-VPS-sleutelpaar decoratie.

  De testomgeving heeft een vaste sleutel in `config/test.exs`, dus dit pad is
  hier standaard aan -- net als in productie. Geen enkele test verzet hier de
  globale configuratie: dat lekt naar tests die er parallel naast draaien, en
  precies dat liet deze suite eerder omvallen in `provisioning_test.exs`.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Console.Keys
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp regio_met_node do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
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

    region
  end

  defp bestel(region) do
    {:ok, %{vps: vps, command: %Command{payload: payload}}} =
      Provisioning.create_vps(%{
        name: "Console",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        ssh_keys: ["ssh-ed25519 VANDEKLANT klant@thuis"]
      })

    {vps, payload["ssh_keys"]}
  end

  test "de VPS krijgt een eigen sleutel, naast die van de klant zelf" do
    region = regio_met_node()
    {vps, sleutels} = bestel(region)

    opgeslagen = Repo.get!(Vps, vps.id)
    assert is_binary(opgeslagen.console_key_sealed)
    assert String.starts_with?(opgeslagen.console_key_public, "ssh-rsa ")

    assert sleutels == ["ssh-ed25519 VANDEKLANT klant@thuis", opgeslagen.console_key_public]
  end

  test "twee VPS'en delen hun sleutel niet" do
    # Dit is het hele punt: één sleutel voor iedereen betekende dat wie hem in
    # handen kreeg root had op elke klant.
    region = regio_met_node()
    {een, _} = bestel(region)
    {twee, _} = bestel(region)

    a = Repo.get!(Vps, een.id)
    b = Repo.get!(Vps, twee.id)

    refute a.console_key_public == b.console_key_public
    refute a.console_key_sealed == b.console_key_sealed
  end

  test "de opgeslagen sleutel is weer te openen en bruikbaar voor ssh" do
    region = regio_met_node()
    {vps, _} = bestel(region)

    assert {:ok, pem} = Keys.unseal(Repo.get!(Vps, vps.id).console_key_sealed)
    assert [entry | _] = :public_key.pem_decode(pem)
    assert {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = :public_key.pem_entry_decode(entry)
  end

  test "een verzoek kan zijn eigen publieke sleutel niet opgeven" do
    # Dat zou de sleutel zijn die root geeft op die machine, dus hij staat
    # bewust niet in de cast van de changeset.
    region = regio_met_node()

    # Beide schrijfwijzen, want de aanroeper accepteert atoom- en tekstsleutels.
    # Los opgebouwd: Elixir staat de korte `key:`-vorm alleen als laatste in een
    # map-literal toe, en door elkaar heen is het een syntaxfout.
    smokkel =
      %{name: "Smokkel", region_id: region.id, vcpu: 1, ram_mb: 1024, disk_gb: 20}
      |> Map.put(:console_key_public, "ssh-rsa VANDEAANVALLER")
      |> Map.put("console_key_public", "ssh-rsa VANDEAANVALLER")

    {:ok, %{vps: vps}} = Provisioning.create_vps(smokkel)

    refute Repo.get!(Vps, vps.id).console_key_public == "ssh-rsa VANDEAANVALLER"
  end
end
