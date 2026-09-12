defmodule ControlPlane.NetTest do
  use ExUnit.Case, async: true

  alias ControlPlane.Net

  describe "from_ip_config/1" do
    test "pulls the address out of a Proxmox ip_config" do
      assert Net.from_ip_config("ip=10.10.4.20/22,gw=10.10.4.1") == "10.10.4.20"
      assert Net.from_ip_config("gw=10.10.4.1,ip=10.10.4.20/22") == "10.10.4.20"
    end

    test "a malformed config yields nothing rather than a wrong address" do
      # The result is treated as authoritative — it becomes the address the
      # console binds to — so a half-parsed value is worse than none.
      for bad <- [
            "",
            "gw=10.10.4.1",
            "ip=999.999.999.999/22",
            "ip=nonsense",
            "dhcp",
            nil,
            42
          ] do
        assert is_nil(Net.from_ip_config(bad)), "accepted #{inspect(bad)}"
      end
    end

    test "does not match an address that merely appears in the string" do
      assert is_nil(Net.from_ip_config("comment=10.10.4.20 is the old one"))
    end
  end
end
