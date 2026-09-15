defmodule ControlPlaneWeb.WorkerInstallController do
  @moduledoc """
  Serves the interactive bunk-worker install wizard (`curl … | bash`).

  The wizard runs on any Linux machine that can reach the node's Proxmox or ESXi
  API over the network. Running it on the Proxmox host itself is the better
  choice where that is possible: only there can the agent build the customer
  network (bridge, gateway, NAT) from the subnet the control plane assigns, so
  the operator does not have to get an IP plan right by hand. Elsewhere — a
  separate VM, or ESXi, which has no Linux host to configure — the operator
  declares the network they already run and owns it.
  """
  use ControlPlaneWeb, :controller

  # De updater staat als losse bestanden in priv/agent-update/ zodat hij te
  # lezen en te testen is zonder een shellscript uit een Elixir-string te moeten
  # pellen. Ze worden hier bij het compileren ingelezen; @external_resource zorgt
  # dat een wijziging eraan deze module opnieuw laat compileren.
  #
  # In priv/ en niet ergens boven de app: de gate en het productie-image bouwen
  # alleen control_plane/, dus een pad daarbuiten bestaat in de container niet.
  @update_dir Path.join([__DIR__, "..", "..", "..", "priv", "agent-update"])
  @update_script_path Path.expand(Path.join(@update_dir, "bunk-agent-update"))
  @update_service_path Path.expand(Path.join(@update_dir, "bunk-agent-update.service"))
  @update_timer_path Path.expand(Path.join(@update_dir, "bunk-agent-update.timer"))

  @external_resource @update_script_path
  @external_resource @update_service_path
  @external_resource @update_timer_path

  @update_script File.read!(@update_script_path)
  @update_service File.read!(@update_service_path)
  @update_timer File.read!(@update_timer_path)

  @doc """
  De updater als los script, voor een node die al draait.

  `curl -fsSL <cp>/agent-update.sh | sh` zet het script, de service en de timer
  neer en draait de controle meteen één keer. Nodes die met de huidige
  `install.sh` zijn opgezet hebben dit al.
  """
  def update_bootstrap(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, bootstrap())
  end

  defp bootstrap do
    """
    #!/bin/sh
    set -eu
    [ "$(id -u)" = "0" ] || { echo "Dit moet als root."; exit 1; }

    cat > /usr/local/bin/bunk-agent-update <<'UPD'
    #{@update_script}
    UPD
    chmod +x /usr/local/bin/bunk-agent-update

    cat > /etc/systemd/system/bunk-agent-update.service <<'UPDSVC'
    #{@update_service}
    UPDSVC

    cat > /etc/systemd/system/bunk-agent-update.timer <<'UPDTMR'
    #{@update_timer}
    UPDTMR

    systemctl daemon-reload
    systemctl enable --now bunk-agent-update.timer
    echo "Automatische updates staan aan. Nu eenmalig controleren..."
    /usr/local/bin/bunk-agent-update || true
    """
  end

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
    # bunk-worker installer. Run on a Linux machine that can reach your Proxmox
    # OR ESXi API over the network. On Proxmox, running it on the host itself
    # lets the agent set up the customer network for you; anywhere else you
    # declare the network you already run.
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
        install -d -m 755 /usr/local/bin
        gtmp="$(mktemp)"
        curl -fsSL https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o "$gtmp" || { echo "!! govc-download mislukt (schijf vol of geen netwerk? check: df -h /)"; rm -f "$gtmp"; return 1; }
        tar -xzf "$gtmp" -C /usr/local/bin govc || { echo "!! govc uitpakken mislukt"; rm -f "$gtmp"; return 1; }
        rm -f "$gtmp"
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
    echo "ESXi-API over het netwerk. Draai je hem op de Proxmox-host zelf, dan"
    echo "kan Bunk ook het klantnetwerk voor je opzetten."
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
    echo "Hoeveel van deze machine gaat naar de VPS-pool? (leeg = alles)"
    read -r -p "  vCPU-cores: " OFFER_VCPU </dev/tty
    read -r -p "  RAM in MB:  " OFFER_RAM </dev/tty
    read -r -p "  Disk in GB: " OFFER_DISK </dev/tty

    echo
    echo "Netwerk voor de VPS'en op deze node:"
    # Two ways to run this. On the Proxmox host itself the agent can build the
    # customer network (bridge + gateway + NAT) from the subnet the control plane
    # assigns, and the operator is asked nothing beyond a bridge name. Anywhere
    # else -- the agent on a separate VM, or ESXi, where there is no Linux host to
    # configure -- the operator owns the network and declares it here.
    #
    # Bridge/VLAN are Proxmox-only concepts (the Proxmox provider forces the NIC
    # bridge + 802.1q tag). On ESXi a VM's network is a *port group* and the
    # clone inherits it from the template, so we neither ask nor pass it there.
    VPS_BRIDGE=""
    VPS_VLAN=0
    VPS_GW=""; VPS_CIDR=""; VPS_RSTART=""; VPS_REND=""
    MANAGE_NET=false

    ON_PVE_HOST=false
    [ "$HYP" = "proxmox" ] && [ -d /etc/pve ] && [ -x /usr/sbin/qm ] && ON_PVE_HOST=true

    if [ "$ON_PVE_HOST" = "true" ]; then
      echo "  Deze machine is de Proxmox-host zelf."
      echo "  Bunk kan het klantnetwerk dan zelf opzetten: een eigen subnet per node,"
      echo "  een gateway op een bestaande bridge, en uitgaand verkeer via jouw uplink."
      echo "  Zeg NEE als er al een router (bv. een OPNsense/OpenWrt-VM) de gateway"
      echo "  van dat netwerk beheert -- twee machines op hetzelfde adres breekt het."
      read -r -p "  Netwerk door Bunk laten beheren? (j/N): " MN </dev/tty
      case "$MN" in j|J|y|Y) MANAGE_NET=true;; *) MANAGE_NET=false;; esac
    fi

    if [ "$MANAGE_NET" = "true" ]; then
      echo "  De bridge moet al bestaan (Proxmox > Node > Network > Create > Linux Bridge)."
      read -r -p "  Bridge voor VPS-verkeer [vmbr2]: " VPS_BRIDGE </dev/tty
      VPS_BRIDGE="${VPS_BRIDGE:-vmbr2}"
      if ! ip link show "$VPS_BRIDGE" >/dev/null 2>&1; then
        echo "  !! $VPS_BRIDGE bestaat nog niet op deze machine. Maak hem eerst aan;"
        echo "     de agent draait wel, maar zet het netwerk pas op als de bridge er is."
      fi
      read -r -p "  VLAN-tag (0 = geen VLAN): " VPS_VLAN </dev/tty; VPS_VLAN="${VPS_VLAN:-0}"
      echo "  -> Het subnet wordt toegewezen door de control plane; je hoeft zelf"
      echo "     geen gateway of IP-range op te geven."
    else
      if [ "$HYP" = "proxmox" ]; then
        read -r -p "  Bridge (bv. vmbr0; leeg = van de template overnemen): " VPS_BRIDGE </dev/tty
        read -r -p "  VLAN-tag (0 = geen VLAN): " VPS_VLAN </dev/tty; VPS_VLAN="${VPS_VLAN:-0}"
      else
        echo "  VPS'en gebruiken de port group / netwerk-adapter van de template."
      fi
      echo "  Je beheert het netwerk zelf. Geef op welk subnet de VPS'en krijgen --"
      echo "  de gateway hieronder moet echt bestaan en verkeer doorlaten."
      read -r -p "  Gateway voor VPS'en (bv. 192.168.1.1): " VPS_GW </dev/tty
      read -r -p "  Subnet-prefix (bv. 24): " VPS_CIDR </dev/tty
      read -r -p "  Eerste bruikbare IP (bv. 192.168.1.100): " VPS_RSTART </dev/tty
      read -r -p "  Laatste bruikbare IP (bv. 192.168.1.150): " VPS_REND </dev/tty
    fi

    echo
    if [ "$HYP" = "esxi" ]; then
      ensure_esxi_template || echo "(template-stap overgeslagen — zie melding hierboven)"
    fi

    echo
    echo "-> bunk-worker binary downloaden..."
    install -d -m 755 /usr/local/bin
    btmp="$(mktemp)"
    curl -fsSL "$CP/dist/bunk-worker" -o "$btmp" || { echo "!! Kon de bunk-worker binary niet wegschrijven — schijf vol? Check met: df -h /"; rm -f "$btmp"; exit 1; }
    # Integriteitscheck: vergelijk met de checksum die naast de binary is
    # gepubliceerd. Vangt afgekapte/corrupte downloads (bv. een verbroken
    # verbinding of proxy-truncatie) vóórdat er iets als root wordt geïnstalleerd.
    expected="$(curl -fsSL "$CP/dist/bunk-worker.sha256" 2>/dev/null | awk '{print $1}')" || expected=""
    if [ -n "$expected" ]; then
      actual="$(sha256sum "$btmp" | awk '{print $1}')"
      if [ "$expected" != "$actual" ]; then
        echo "!! Checksum-mismatch op de gedownloade binary (verwacht $expected, kreeg $actual)."
        echo "!! Download opnieuw of neem contact op — er wordt NIETS geinstalleerd."
        rm -f "$btmp"; exit 1
      fi
      echo "   checksum OK ($actual)"
    else
      echo "   (geen checksum gepubliceerd op $CP/dist/bunk-worker.sha256 — stap overgeslagen)"
    fi
    install -m 755 "$btmp" /usr/local/bin/bunk-worker
    rm -f "$btmp"
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
    Environment=BUNK_MANAGE_NETWORK=${MANAGE_NET}
    Environment=BUNK_STATE_DIR=/var/lib/bunk-worker
    ExecStart=/usr/local/bin/bunk-worker
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    UNIT

    echo "-> automatische updates instellen..."
    cat > /usr/local/bin/bunk-agent-update <<'UPD'
    #{@update_script}
    UPD
    chmod +x /usr/local/bin/bunk-agent-update

    cat > /etc/systemd/system/bunk-agent-update.service <<'UPDSVC'
    #{@update_service}
    UPDSVC

    cat > /etc/systemd/system/bunk-agent-update.timer <<'UPDTMR'
    #{@update_timer}
    UPDTMR

    systemctl daemon-reload
    systemctl enable --now bunk-agent-update.timer
    systemctl enable --now bunk-worker
    sleep 2
    echo
    bold "== Klaar! =="
    echo "Je worker verbindt nu met $CP en biedt capaciteit aan."
    if [ "$MANAGE_NET" = "true" ]; then
      echo "Het klantnetwerk wordt opgezet op $VPS_BRIDGE zodra de node is ingeschreven;"
      echo "welk subnet je kreeg zie je in de logs ('vps network ready')."
    else
      echo "Let op: je beheert het netwerk zelf. VPS'en krijgen gateway $VPS_GW --"
      echo "zonder werkende gateway en NAT hebben ze geen verbinding."
    fi
    echo "Status:  systemctl status bunk-worker"
    echo "Logs:    journalctl -u bunk-worker -f"
    """
  end
end
