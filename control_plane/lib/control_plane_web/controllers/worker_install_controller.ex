defmodule ControlPlaneWeb.WorkerInstallController do
  @moduledoc """
  Serves the interactive bunk-worker install wizard (`curl … | bash`).

  The wizard runs on any Linux machine (a small VM is ideal) that can reach the
  operator's Proxmox or ESXi API over the network — it does NOT run on, or need
  root on, the hypervisor host itself.
  """
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
    # bunk-worker installer. Run on a Linux machine (a small VM is ideal) that can
    # reach your Proxmox OR ESXi API over the network. It does NOT run on, and
    # does not need root on, the hypervisor host itself — it talks to the API.
    set -euo pipefail
    CP="#{cp}"
    TOKEN=""
    HYP=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --token) TOKEN="$2"; shift 2;;
        --token=*) TOKEN="${1#*=}"; shift;;
        --hypervisor) HYP="$2"; shift 2;;
        --hypervisor=*) HYP="${1#*=}"; shift;;
        *) shift;;
      esac
    done

    bold() { printf "\\033[1m%s\\033[0m\\n" "$1"; }
    bold "== Bunk Worker installatie =="
    echo "Control plane: $CP"
    echo "Deze worker draait op DEZE Linux-machine en praat met je Proxmox- of"
    echo "ESXi-API over het netwerk — niet op de hypervisor zelf."
    echo

    [ -z "$TOKEN" ] && read -r -p "Enroll-token (uit de portal): " TOKEN </dev/tty
    [ -z "$TOKEN" ] && { echo "Een enroll-token is verplicht."; exit 1; }

    [ -z "$HYP" ] && read -r -p "Hypervisor (proxmox/esxi) [proxmox]: " HYP </dev/tty
    HYP="${HYP:-proxmox}"
    # Normalise so "ESXi", " esxi ", "vSphere", "PVE" etc. all match.
    HYP="$(printf '%s' "$HYP" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$HYP" in pve) HYP=proxmox;; vmware|vsphere|vcenter) HYP=esxi;; esac
    PXHOST=""; PXNODE=""; PXTID=""; PXSEC=""; VSSL=false
    ESXI_URL=""; ESXI_USER=""; ESXI_PASS=""; ESXI_INSECURE=false; ESXI_DS=""; ESXI_RP=""; ESXI_TMPL=""
    if [ "$HYP" = "proxmox" ]; then
      read -r -p "Proxmox API host (https://IP:8006): " PXHOST </dev/tty
      read -r -p "Proxmox node-naam (bv. pve): " PXNODE </dev/tty
      read -r -p "Proxmox API token-id (user@realm!tokenid): " PXTID </dev/tty
      read -r -s -p "Proxmox API token-secret: " PXSEC </dev/tty; echo
      read -r -p "TLS-certificaat verifiëren? (j/N): " VS </dev/tty; case "$VS" in j|J|y|Y) VSSL=true;; *) VSSL=false;; esac
    elif [ "$HYP" = "esxi" ]; then
      read -r -p "vSphere/ESXi URL (https://host/sdk): " ESXI_URL </dev/tty
      read -r -p "Gebruiker: " ESXI_USER </dev/tty
      read -r -s -p "Wachtwoord: " ESXI_PASS </dev/tty; echo
      read -r -p "TLS-certificaat verifiëren? (j/N): " VS </dev/tty; case "$VS" in j|J|y|Y) ESXI_INSECURE=false;; *) ESXI_INSECURE=true;; esac
      read -r -p "Datastore (leeg = standaard): " ESXI_DS </dev/tty
      read -r -p "Resource pool (leeg = standaard): " ESXI_RP </dev/tty
      read -r -p "Template-VM naam (verplicht): " ESXI_TMPL </dev/tty
    else
      echo "Onbekende hypervisor: $HYP"; exit 1
    fi
    echo
    echo "Hoeveel capaciteit wil je aanbieden? (leeg laten = alles beschikbaar)"
    read -r -p "  vCPU-cores: " OFFER_VCPU </dev/tty
    read -r -p "  RAM in MB:  " OFFER_RAM </dev/tty
    read -r -p "  Disk in GB: " OFFER_DISK </dev/tty

    echo
    echo "Netwerk voor je VPS'en (leeg laten = standaard/Bunk-bereik):"
    echo "  1) Zelfde subnet als deze host (geen VLAN)"
    echo "  2) Apart VLAN/subnet voor VPS'en"
    read -r -p "Keuze [1]: " NETMODE </dev/tty; NETMODE="${NETMODE:-1}"
    read -r -p "  Bridge (bv. vmbr0): " VPS_BRIDGE </dev/tty
    VPS_VLAN=0
    if [ "$NETMODE" = "2" ]; then
      read -r -p "  VLAN-tag: " VPS_VLAN </dev/tty
    fi
    read -r -p "  Gateway voor VPS'en (bv. 192.168.1.1): " VPS_GW </dev/tty
    read -r -p "  Subnet-prefix (bv. 24): " VPS_CIDR </dev/tty
    read -r -p "  Eerste bruikbare IP (bv. 192.168.1.100): " VPS_RSTART </dev/tty
    read -r -p "  Laatste bruikbare IP (bv. 192.168.1.150): " VPS_REND </dev/tty

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
    Environment=BUNK_ESXI_URL=${ESXI_URL}
    Environment=BUNK_ESXI_USER=${ESXI_USER}
    Environment=BUNK_ESXI_PASSWORD=${ESXI_PASS}
    Environment=BUNK_ESXI_INSECURE=${ESXI_INSECURE:-false}
    Environment=BUNK_ESXI_DATASTORE=${ESXI_DS}
    Environment=BUNK_ESXI_RESOURCE_POOL=${ESXI_RP}
    Environment=BUNK_ESXI_TEMPLATE=${ESXI_TMPL}
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
