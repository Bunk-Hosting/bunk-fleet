alias ControlPlane.{Repo, Provisioning, Fleet}
region_id = File.read!("/work/region_id.txt")
{:ok, %{vps: vps}} = Provisioning.create_vps(%{
  region_id: region_id, name: "bf-e2e-1", vcpu: 1, ram_mb: 512, disk_gb: 5,
  owner_email: "e2e@bunkhosting.nl", template_id: 9000, ip_config: "ip=dhcp",
  ssh_keys: [], cloud_init: %{}})
File.write!("/work/vps_id.txt", vps.id)
IO.puts("VPS_CREATED " <> vps.id)
