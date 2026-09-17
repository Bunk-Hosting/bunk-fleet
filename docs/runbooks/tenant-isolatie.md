# Tenant-isolatie aanzetten op een Proxmox-node

**Wat dit oplost.** Alle klant-VPSen hangen aan dezelfde bridge. Hun onderlinge
verkeer wordt daardoor op laag 2 geschakeld en komt nooit langs de
FORWARD-keten van de node — `iptables` op de host ziet het niet eens. Een klant
kan zonder deze stap zijn buren bereiken, hun verkeer meelezen na een ARP-truc,
en zich voordoen als de gateway.

**Wat de agent al doet.** Sinds september 2026 zet de agent bij elke nieuwe VPS
de firewall van díé gast goed: `firewall=1` op de netwerkkaart, `ipfilter` met
alleen het eigen IP, en een DROP naar het klantsubnet met de gateway
uitgezonderd. Zolang de firewall op datacenterniveau uitstaat doen die
instellingen **niets**. Ze staan alvast klaar.

**Wat jij doet.** De knop op datacenterniveau omzetten. Die staat bewust niet in
de agent: een verkeerd geconfigureerde firewall kan je buiten je eigen node
sluiten, en dat hoort een mens te doen die er fysiek bij kan.

---

## Vóór je begint

1. **Zorg dat je bij de node kunt zonder SSH.** De Proxmox-webconsole via een
   ander netwerk, of fysiek toetsenbord. Dit is de hele reden dat deze stap niet
   geautomatiseerd is: als je jezelf buitensluit is SSH precies wat je kwijt
   bent.
2. **Controleer dat de host-regels er staan**, anders sluit je met de
   datacenter-policy je eigen beheerverkeer af:

   ```
   pvesh get /cluster/firewall/rules
   pvesh get /nodes/<node>/firewall/rules
   ```

   Staat er niets, maak dan eerst een regel die SSH (22) en de Proxmox-webinterface
   (8006) toelaat vanaf je beheernetwerk. **Doe dit vóór stap 2 hieronder.**

3. Noteer hoe je terugkomt (zie "Als het misgaat").

## Aanzetten

1. Cluster-regels voor je eigen toegang, als ze er nog niet zijn:

   ```
   pvesh create /cluster/firewall/rules --type in --action ACCEPT \
     --dest <ip-van-de-node> --dport 8006 --source <jouw-beheernetwerk> --enable 1
   pvesh create /cluster/firewall/rules --type in --action ACCEPT \
     --dest <ip-van-de-node> --dport 22 --source <jouw-beheernetwerk> --enable 1
   ```

2. Firewall aan op datacenterniveau:

   ```
   pvesh set /cluster/firewall/options --enable 1
   ```

3. Controleer dat je nog steeds binnen kunt (open een TWEEDE sessie; sluit de
   eerste niet).

4. Controleer dat een bestaande VPS nog werkt: open de webterminal in het
   dashboard en ping de gateway.

## Controleren dat het werkt

Op een testmachine, niet op die van een klant:

```
# vanaf VPS A naar VPS B in hetzelfde subnet — hoort te FALEN
ping -c 2 <ip-van-vps-B>

# naar de gateway — hoort te WERKEN
ping -c 2 <gateway-ip>

# naar buiten — hoort te WERKEN
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com
```

Werkt de eerste wél, controleer dan of de VPS na de wijziging opnieuw is
uitgerold: de agent zet deze instellingen bij het AANMAKEN. Machines van vóór
die versie hebben ze niet. Voor bestaande gasten:

```
pvesh set /nodes/<node>/qemu/<vmid>/firewall/options --enable 1 --ipfilter 1 \
  --policy_in ACCEPT --policy_out ACCEPT
pvesh create /nodes/<node>/qemu/<vmid>/firewall/ipset --name ipfilter-net0
pvesh create /nodes/<node>/qemu/<vmid>/firewall/ipset/ipfilter-net0 --cidr <ip-van-de-vps>
```

en zet daarna in de VM-config `firewall=1` op net0 (Proxmox UI → VM → Hardware →
Netwerk → Firewall aanvinken; dat vraagt een herstart van de gast).

## Als het misgaat

**Je kunt er niet meer bij.** Via de fysieke console of de Proxmox-console van
de hostende partij:

```
pvesh set /cluster/firewall/options --enable 0
```

Dat zet alles terug zoals het was; de VM-instellingen blijven staan maar doen
niets meer.

**Eén VPS doet het niet meer.** Zet alleen die gast terug:

```
pvesh set /nodes/<node>/qemu/<vmid>/firewall/options --enable 0
```

**Een klant meldt dat hij zijn eigen tweede VPS niet meer kan bereiken.** Dat is
verwacht gedrag: verkeer tussen VPSen is precies wat hier wordt geblokkeerd. Wil
je dat toestaan voor één klant, voeg dan vóór de DROP-regel een ACCEPT toe met
het adres van zijn andere machine als `dest`.

## Wat dit NIET oplost

- De back-ups van alle klanten staan onversleuteld op dezelfde node-storage.
- Wie de hypervisor beheert kan bij elke virtuele schijf. Dat is inherent aan
  gehoste virtualisatie en staat ook zo in de voorwaarden.
- Nodes waar Bunk het netwerk niet beheert (een eigen router als gateway) hebben
  geen host-firewallregels van ons; poort 25 en snelheidslimieten moeten daar op
  die router.
