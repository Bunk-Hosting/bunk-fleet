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

    # Zero-touch ESXi template: if the chosen template VM doesn't exist yet, pull
    # VMware's own CLI (govc) and import Ubuntu's cloud OVA (cloud-init +
    # open-vm-tools ready) as a template. Best-effort — a failure is reported but
    # doesn't abort the agent install.
    ensure_esxi_template() {
      export GOVC_URL="$ESXI_URL" GOVC_USERNAME="$ESXI_USER" GOVC_PASSWORD="$ESXI_PASS"
      [ "$ESXI_INSECURE" = "true" ] && export GOVC_INSECURE=1
      [ -n "$ESXI_DC" ] && export GOVC_DATACENTER="$ESXI_DC"
      if ! command -v govc >/dev/null 2>&1; then
        echo "-> govc (VMware CLI) ophalen..."
        curl -fsSL https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz | tar -xzf - -C /usr/local/bin govc || { echo "!! govc-download mislukt"; return 1; }
        chmod +x /usr/local/bin/govc
      fi
      if govc vm.info "$ESXI_TMPL" >/dev/null 2>&1; then
        echo "-> Template '$ESXI_TMPL' bestaat al — geen actie nodig."
        return 0
      fi
      echo "-> Template '$ESXI_TMPL' ontbreekt; Ubuntu cloud-OVA importeren (kan enkele minuten duren)..."
      ova="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.ova"
      args="-name=$ESXI_TMPL"
      [ -n "$ESXI_DC" ] && args="$args -dc=$ESXI_DC"
      [ -n "$ESXI_DS" ] && args="$args -ds=$ESXI_DS"
      [ -n "$ESXI_RP" ] && args="$args -pool=$ESXI_RP"
      [ -n "$ESXI_FOLDER" ] && args="$args -folder=$ESXI_FOLDER"
      if govc import.ova $args "$ova" && govc vm.markastemplate "$ESXI_TMPL"; then
        echo "-> Template '$ESXI_TMPL' aangemaakt en klaar voor gebruik."
      else
        echo "!! Kon de template niet automatisch aanmaken (check datastore/resource-pool/netwerk/rechten)."
        echo "   De agent draait wel, maar kan pas VPS'en aanmaken zodra er een cloud-init template bestaat."
        return 1
      fi
    }

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
    ESXI_URL=""; ESXI_USER=""; ESXI_PASS=""; ESXI_INSECURE=false; ESXI_DC=""; ESXI_DS=""; ESXI_RP=""; ESXI_FOLDER=""; ESXI_TMPL=""
    if [ "$HYP" = "proxmox" ]; then
      read -r -p "Proxmox API host (https://IP:8006): " PXHOST </dev/tty
      read -r -p "Proxmox node-naam (bv. pve): " PXNODE </dev/tty
      read -r -p "Proxmox API token-id (user@realm!tokenid): " PXTID </dev/tty
      read -r -s -p "Proxmox API token-secret: " PXSEC </dev/tty; echo
      read -r -p "TLS-certificaat verifiëren? (j/N): " VS </dev/tty; case "$VS" in j|J|y|Y) VSSL=true;; *) VSSL=false;; esac
    elif [ "$HYP" = "esxi" ]; then
      read -r -p "vSphere/ESXi adres (bv. 192.168.1.50 of vcenter.school.nl): " ESXI_URL </dev/tty
      # Accept a bare IP/hostname: add the scheme + /sdk path govmomi expects,
      # so "192.168.1.50" becomes "https://192.168.1.50/sdk" (fixes the common
      # "unsupported protocol scheme" error from leaving those off).
      case "$ESXI_URL" in http://*|https://*) : ;; *) ESXI_URL="https://$ESXI_URL" ;; esac
      case "$ESXI_URL" in */sdk|*/sdk/) : ;; *) ESXI_URL="${ESXI_URL%/}/sdk" ;; esac
      echo "   -> gebruik URL: $ESXI_URL"
      read -r -p "Gebruiker (bv. administrator@vsphere.local): " ESXI_USER </dev/tty
      read -r -s -p "Wachtwoord: " ESXI_PASS </dev/tty; echo
      read -r -p "TLS-certificaat verifiëren? (j/N): " VS </dev/tty; case "$VS" in j|J|y|Y) ESXI_INSECURE=false;; *) ESXI_INSECURE=true;; esac
      # Datacenter/folder matter on vCenter (multiple of each); on a standalone
      # ESXi host leave them empty and the default is used.
      read -r -p "Datacenter (vCenter; leeg = standaard/losse ESXi-host): " ESXI_DC </dev/tty
      read -r -p "Datastore (leeg = standaard): " ESXI_DS </dev/tty
      read -r -p "Resource pool of cluster (leeg = standaard): " ESXI_RP </dev/tty
      read -r -p "VM-folder (leeg = standaard): " ESXI_FOLDER </dev/tty
      read -r -p "Template-VM naam (leeg = automatisch aanmaken): " ESXI_TMPL </dev/tty
      ESXI_TMPL="${ESXI_TMPL:-bunk-ubuntu-2204}"
    else
      echo "Onbekende hypervisor: $HYP"; exit 1
    fi
    echo
    echo "Hoeveel capaciteit wil je aanbieden? (leeg laten = alles beschikbaar)"
    read -r -p "  vCPU-cores: " OFFER_VCPU </dev/tty
    read -r -p "  RAM in MB:  " OFFER_RAM </dev/tty
    read -r -p "  Disk in GB: " OFFER_DISK </dev/tty

    echo
    echo "Netwerk voor je VPS'en:"
    # Bridge/VLAN are Proxmox-only concepts (the Proxmox provider forces the NIC
    # bridge + 802.1q tag). On ESXi a VM's network is a *port group* and the
    # clone inherits it from the template, so we neither ask nor pass it there.
    VPS_BRIDGE=""
    VPS_VLAN=0
    if [ "$HYP" = "proxmox" ]; then
      read -r -p "  Bridge (bv. vmbr0; leeg = van de template overnemen): " VPS_BRIDGE </dev/tty
      read -r -p "  VLAN-tag (0 = geen VLAN): " VPS_VLAN </dev/tty; VPS_VLAN="${VPS_VLAN:-0}"
    else
      echo "  VPS'en gebruiken de port group / netwerk-adapter van de template."
    fi
    read -r -p "  Gateway voor VPS'en (bv. 192.168.1.1): " VPS_GW </dev/tty
    read -r -p "  Subnet-prefix (bv. 24): " VPS_CIDR </dev/tty
    read -r -p "  Eerste bruikbare IP (bv. 192.168.1.100): " VPS_RSTART </dev/tty
    read -r -p "  Laatste bruikbare IP (bv. 192.168.1.150): " VPS_REND </dev/tty

    echo
    if [ "$HYP" = "esxi" ]; then
      ensure_esxi_template || echo "(template-stap overgeslagen — zie melding hierboven)"
    fi

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
    Environment=BUNK_ESXI_DATACENTER=${ESXI_DC}
    Environment=BUNK_ESXI_DATASTORE=${ESXI_DS}
    Environment=BUNK_ESXI_RESOURCE_POOL=${ESXI_RP}
    Environment=BUNK_ESXI_FOLDER=${ESXI_FOLDER}
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
