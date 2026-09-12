defmodule ControlPlane.ProvisioningSecretsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp provision_command(payload) do
    r = region()
    node = node_in(r)

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "v-#{System.unique_integer([:positive])}",
        region_id: r.id,
        node_id: node.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        status: :provisioning
      })
      |> Repo.insert!()

    %Command{}
    |> Command.changeset(%{
      node_id: node.id,
      vps_id: vps.id,
      kind: :provision,
      status: :delivered,
      payload: payload
    })
    |> Repo.insert!()
  end

  test "a cloud-init password does not outlive the command that carried it" do
    # Commands are durable rows. Without scrubbing, a customer's VM password sits
    # in the database in plaintext for the life of the platform, long after the
    # VPS it belonged to is gone.
    command =
      provision_command(%{
        "name" => "web",
        "cloud_init" => %{"user" => "stijn", "password" => "geheim-wachtwoord"}
      })

    {:ok, _} = Provisioning.apply_result(command, %{"status" => "done", "vm_id" => "106"})

    payload = Repo.get!(Command, command.id).payload
    refute payload["cloud_init"]["password"]
    assert payload["cloud_init"]["user"] == "stijn"
    assert payload["name"] == "web"
  end

  test "a failed provision scrubs the password too" do
    # A failure is not a reason to keep it — arguably the opposite, since the
    # row will be looked at by a human.
    command =
      provision_command(%{"cloud_init" => %{"password" => "geheim"}})

    {:ok, _} = Provisioning.apply_result(command, %{"status" => "failed", "error" => "boom"})

    refute Repo.get!(Command, command.id).payload["cloud_init"]["password"]
  end

  test "a payload without cloud-init is left exactly as it was" do
    command = provision_command(%{"vm_id" => "106", "ssh_keys" => ["ssh-ed25519 AAAA"]})

    {:ok, _} = Provisioning.apply_result(command, %{"status" => "done", "vm_id" => "106"})

    payload = Repo.get!(Command, command.id).payload
    assert payload["vm_id"] == "106"
    assert payload["ssh_keys"] == ["ssh-ed25519 AAAA"]
  end
end
