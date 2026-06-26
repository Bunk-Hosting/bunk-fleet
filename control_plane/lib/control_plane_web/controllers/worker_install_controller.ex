defmodule ControlPlaneWeb.WorkerInstallController do
  @moduledoc "Serves the interactive bunk-worker install wizard (curl | bash)."
  use ControlPlaneWeb, :controller

  def script(conn, _params) do
    cp = Application.get_env(:control_plane, :public_url) || request_base(conn)

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, wizard(cp))
  end

  defp request_base(%{scheme: scheme, host: host, port: port}) do
    p = if port in [80, 443], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{p}"
  end

  defp wizard(cp) do
    """
    #!/usr/bin/env bash
    # bunk-worker installer — run as root on your Proxmox host to offer VPS capacity.
    set -euo pipefail
    CP="#{cp}"
    TOKEN=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --token) TOKEN="$2"; shift 2;;
        --token=*) TOKEN="${1#*=}"; shift;;
        *) shift;;
      esac
    done

    bold() { printf "\\033[1m%s\\033[0m\\n" "$1"; }
    bold "== Bunk Worker installatie =="
    echo "Control plane: $CP"
    echo

    [ -z "$TOKEN" ] && read -rp "Enroll-token (uit de portal): " TOKEN
    [ -z "$TOKEN" ] && { echo "Een enroll-token is verplicht."; exit 1; }

    read -rp "Hypervisor (proxmox) [proxmox]: " HYP; HYP="${HYP:-proxmox}"
    if [ "$HYP" != "proxmox" ]; then
      echo "Op dit moment wordt alleen Proxmox ondersteund (ESXi volgt)."; exit 1
    fi
    read -rp "Proxmox API host (https://IP:8006): " PXHOST
    read -rp "Proxmox node-naam (bv. pve): " PXNODE
    read -rp "Proxmox API token-id (user@realm!tokenid): " PXTID
    read -rsp "Proxmox API token-secret: " PXSEC; echo
    read -rp "TLS-certificaat verifiëren? (j/N): " VSSL
    case "$VSSL" in j|J|y|Y) VSSL=true;; *) VSSL=false;; esac
    echo
    echo "Hoeveel capaciteit wil je aanbieden? (leeg laten = alles beschikbaar)"
    read -rp "  vCPU-cores: " OFFER_VCPU
    read -rp "  RAM in MB:  " OFFER_RAM
    read -rp "  Disk in GB: " OFFER_DISK

    echo
    echo "Netwerk voor je VPS'en (leeg laten = standaard/Bunk-bereik):"
    echo "  1) Zelfde subnet als deze host (geen VLAN)"
    echo "  2) Apart VLAN/subnet voor VPS'en"
    read -rp "Keuze [1]: " NETMODE; NETMODE="${NETMODE:-1}"
    read -rp "  Bridge (bv. vmbr0): " VPS_BRIDGE
    VPS_VLAN=0
    if [ "$NETMODE" = "2" ]; then
      read -rp "  VLAN-tag: " VPS_VLAN
    fi
    read -rp "  Gateway voor VPS'en (bv. 192.168.1.1): " VPS_GW
    read -rp "  Subnet-prefix (bv. 24): " VPS_CIDR
    read -rp "  Eerste bruikbare IP (bv. 192.168.1.100): " VPS_RSTART
    read -rp "  Laatste bruikbare IP (bv. 192.168.1.150): " VPS_REND

    echo
    echo "-> bunk-worker binary downloaden..."
    curl -fsSL "$CP/dist/bunk-worker" -o /usr/local/bin/bunk-worker
    chmod +x /usr/local/bin/bunk-worker
    install -d -m 700 /var/lib/bunk-worker

    echo "-> systemd-service installeren..."
    cat > /etc/systemd/system/bunk-worker.service <<UNIT
    [Unit]
    Description=Bunk Worker agent
    After=network-online.target
    Wants=network-online.target

    [Service]
    Environment=BUNK_CONTROL_PLANE_URL=$CP
    Environment=BUNK_ENROLL_TOKEN=$TOKEN
    Environment=BUNK_HYPERVISOR=$HYP
    Environment=BUNK_PROXMOX_HOST=$PXHOST
    Environment=BUNK_PROXMOX_NODE=$PXNODE
    Environment=BUNK_PROXMOX_TOKEN_ID=$PXTID
    Environment=BUNK_PROXMOX_TOKEN_SECRET=$PXSEC
    Environment=BUNK_PROXMOX_VERIFY_SSL=$VSSL
    Environment=BUNK_OFFER_VCPU=${OFFER_VCPU:-0}
    Environment=BUNK_OFFER_RAM_MB=${OFFER_RAM:-0}
    Environment=BUNK_OFFER_DISK_GB=${OFFER_DISK:-0}
    Environment=BUNK_VPS_BRIDGE=${VPS_BRIDGE}
    Environment=BUNK_VPS_VLAN=${VPS_VLAN:-0}
    Environment=BUNK_VPS_GATEWAY=${VPS_GW}
    Environment=BUNK_VPS_CIDR_PREFIX=${VPS_CIDR}
    Environment=BUNK_VPS_RANGE_START=${VPS_RSTART}
    Environment=BUNK_VPS_RANGE_END=${VPS_REND}
    Environment=BUNK_STATE_DIR=/var/lib/bunk-worker
    ExecStart=/usr/local/bin/bunk-worker
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now bunk-worker
    sleep 2
    echo
    bold "== Klaar! =="
    echo "Je worker verbindt nu met $CP en biedt capaciteit aan."
    echo "Status:  systemctl status bunk-worker"
    echo "Logs:    journalctl -u bunk-worker -f"
    """
  end
end
