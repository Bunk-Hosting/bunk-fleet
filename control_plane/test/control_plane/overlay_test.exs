defmodule ControlPlane.OverlayTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.{Overlay, Enrollment, Repo}
  alias ControlPlane.Fleet.Region

  defp enroll(code, wg) do
    region = %Region{} |> Region.changeset(%{code: code, name: "R"}) |> Repo.insert!()
    {:ok, {pt, _}} = Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: 3600})
    Enrollment.enroll(pt, %{hypervisor: "proxmox", wg_public_key: wg})
  end

  test "hub keypair is a stable 32-byte x25519 singleton" do
    k1 = Overlay.hub_keypair()
    k2 = Overlay.hub_keypair()
    assert k1.hub_public_key == k2.hub_public_key
    assert byte_size(Base.decode64!(k1.hub_public_key)) == 32
    assert byte_size(Base.decode64!(k1.hub_private_key)) == 32
  end

  test "enroll with a wg key assigns an overlay IP + returns params" do
    {:ok, %{node: node, overlay: overlay}} = enroll("wg1", "PUBKEY_A")

    assert is_binary(node.overlay_ip)
    assert node.wg_public_key == "PUBKEY_A"
    assert overlay.hub_public_key == Overlay.hub_public_key()
    assert overlay.endpoint =~ ":51820"
    assert overlay.overlay_ip == node.overlay_ip
    assert overlay.overlay_cidr == "10.99.0.0/16"
    assert overlay.hub_ip == "10.99.0.1"
  end

  test "overlay IPs are distinct across nodes" do
    {:ok, %{node: n1}} = enroll("wg2", "PUBKEY_B")
    {:ok, %{node: n2}} = enroll("wg3", "PUBKEY_C")
    assert n1.overlay_ip != n2.overlay_ip
  end

  test "enroll without a wg key gets no overlay (back-compat)" do
    {:ok, %{node: node, overlay: overlay}} = enroll("wg4", nil)
    assert is_nil(overlay)
    assert is_nil(node.overlay_ip)
  end
end
