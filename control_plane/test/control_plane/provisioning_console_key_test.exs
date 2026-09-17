defmodule ControlPlane.ProvisioningConsoleKeyTest do
  @moduledoc """
  Welke publieke sleutel er in de `authorized_keys` van een nieuwe VPS belandt.

  Dit is het stuk dat het verschil maakt. De sleutel wordt bij het uitrollen via
  cloud-init in de machine gezet en daarna nooit meer; staat de gedeelde
  platformsleutel er alsnog naast, dan is het per-VPS-sleutelpaar decoratie.
  """
  use ControlPlane.DataCase, async: false

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
        disk_gb: 20
      })

    {vps, payload["ssh_keys"]}
  end

  defp met_console(opts) do
    oud = Application.get_env(:control_plane, :console) || []
    Application.put_env(:control_plane, :console, Keyword.merge(oud, opts))
    on_exit(fn -> Application.put_env(:control_plane, :console, oud) end)
  end

  describe "met een omgevingssleutel" do
    setup do
      met_console(
        key_encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        ssh_public_key: "ssh-rsa GEDEELDE platform@bunk"
      )

      :ok
    end

    test "de VPS krijgt zijn eigen sleutel en niet de gedeelde" do
      region = regio_met_node()
      {vps, sleutels} = bestel(region)

      opgeslagen = Repo.get!(Vps, vps.id)
      assert is_binary(opgeslagen.console_key_sealed)
      assert String.starts_with?(opgeslagen.console_key_public, "ssh-rsa ")

      assert sleutels == [opgeslagen.console_key_public]
      refute Enum.any?(sleutels, &String.contains?(&1, "GEDEELDE"))
    end

    test "twee VPS'en delen hun sleutel niet" do
      region = regio_met_node()
      {een, _} = bestel(region)
      {twee, _} = bestel(region)

      a = Repo.get!(Vps, een.id)
      b = Repo.get!(Vps, twee.id)

      refute a.console_key_public == b.console_key_public
      refute a.console_key_sealed == b.console_key_sealed
    end

    test "de opgeslagen sleutel is weer te openen" do
      region = regio_met_node()
      {vps, _} = bestel(region)

      assert {:ok, pem} = Keys.unseal(Repo.get!(Vps, vps.id).console_key_sealed)
      assert [_ | _] = :public_key.pem_decode(pem)
    end
  end

  describe "zonder omgevingssleutel" do
    setup do
      met_console(key_encryption_key: nil, ssh_public_key: "ssh-rsa GEDEELDE platform@bunk")
      :ok
    end

    test "valt een nieuwe VPS terug op de gedeelde sleutel" do
      # Half aanzetten zou een VPS opleveren met een sleutel die niemand meer
      # kan ontsleutelen. Dan liever de oude situatie, zichtbaar en werkend.
      region = regio_met_node()
      {vps, sleutels} = bestel(region)

      assert is_nil(Repo.get!(Vps, vps.id).console_key_sealed)
      assert sleutels == ["ssh-rsa GEDEELDE platform@bunk"]
    end
  end
end
