# Runbook — adding a resource node

Written for the second node in the fleet: someone else's machine, in someone
else's building, on someone else's internet connection. Everything here assumes
that, because the things that only work when the node is on your own LAN are
exactly the things that have bitten us.

The node never needs an inbound port. Enrolment, heartbeats, commands and the
browser console are all the agent dialling out over HTTPS.

---

## 1. What the operator needs before starting

- **Proxmox VE**, reachable at an address the agent can use.
- **An API token** for it: Datacenter → Permissions → API Tokens. The agent needs
  enough rights to clone, configure, start, stop and destroy VMs
  (`PVEVMAdmin` on `/` is the blunt version).
- **A cloud-init template** to clone. Without one the node enrols and heartbeats
  happily and every provision fails.
- **A bridge for customer traffic.** Node → Network → Create → Linux Bridge, no
  ports, no address. `vmbr2` by convention. It must exist before the install: the
  agent will address a bridge, never create one.

Decide one thing up front: **who owns the gateway on that bridge.**

| situation | answer | `BUNK_MANAGE_NETWORK` |
|---|---|---|
| A plain bridge with nothing on it | Bunk builds the network | `1` |
| A router VM (OPNsense, OpenWrt, pfSense) already holds the gateway | the operator | `0` |

The first node in the fleet is the second case — the OpenWRT VM holds
`10.10.0.1`. If Bunk also claimed that address the network would go down, not up,
which is why the default is off and the installer asks.

---

## 2. Mint an enroll token

Tokens are single-use, time-limited, and bound to a region. Pick the region
first: a node in another city is only worth a separate region if you want
customers to be able to *choose* it, and an empty region is never shown to
anyone, so creating it early costs nothing.

```bash
# List regions
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://app.bunkhosting.nl/admin/v1/regions | jq

# Create one, if this node is somewhere new
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"code":"nl-2","name":"Nederland — <plaats>"}' \
  https://app.bunkhosting.nl/admin/v1/regions | jq

# Mint the token (valid one hour)
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"region_id":"<REGION_UUID>","ttl_seconds":3600}' \
  https://app.bunkhosting.nl/admin/v1/enroll-tokens | jq
```

The plaintext token is returned once. Send it over something that is not a
group chat.

---

## 3. Install, on the Proxmox host itself

```bash
curl -fsSL https://app.bunkhosting.nl/install.sh | bash -s -- --token <TOKEN>
```

Run it **on the Proxmox host**, not on a helper VM, unless the operator is
managing the network themselves. Only from the host can the agent put the
gateway on the bridge and NAT customer traffic out of the node's own uplink.

The wizard asks for the API details, how much of the machine to offer, and the
network question from §1. It does not ask for an IP plan: the control plane
assigns the node a `/22` out of `10.10.0.0/16` and hands it back at enrolment.

---

## 4. Check it actually worked

```bash
journalctl -u bunk-worker -f
```

Four lines, in order:

```
enrolled with control plane            node_id=...
control plane assigned the VPS network gateway=10.10.4.1 prefix=22 range=10.10.4.20-10.10.7.254
vps network ready                      bridge=vmbr2 subnet=10.10.4.0/22 uplink=<their uplink>
heartbeat sent                         avail_vcpu=... avail_ram_mb=... avail_disk_gb=...
```

`vps network ready` only appears when Bunk manages the network. With
`BUNK_MANAGE_NETWORK=0` you get "not managed" instead, and the operator owes you
a working gateway on the subnet the control plane assigned.

Then, from your side:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://app.bunkhosting.nl/admin/v1/nodes | jq '.nodes[] | {name, status, region, available_ram_mb}'
```

Order the smallest VPS in that region and open the console. That exercises the
whole chain — scheduler, address allocation, cloud-init, and the console relay
dialling back out of their network — and it is the only check that proves the
node can do the job rather than merely appear.

---

## 5. When something is wrong

**Node never appears.** The token is single-use: if the install was run twice,
the second run consumed nothing and the agent has no credentials. Mint another.

**Node online, every provision fails.** Almost always the template: the name in
`BUNK_ESXI_TEMPLATE` / the Proxmox template id does not exist on that host.

**VPS gets an address but no connectivity.** Ask who owns the gateway. With
`BUNK_MANAGE_NETWORK=1`, `ip addr show vmbr2` on the node should carry the
assigned `.1`, `sysctl net.ipv4.ip_forward` should be 1, and
`iptables -t nat -S POSTROUTING` should have a MASQUERADE line naming the node's
subnet. With `0`, that is all the operator's to check.

**Console spins and gives up.** The agent's log says whether it ever saw the
request (`console session open`) and whether it could reach the VPS. If the
request never arrives, the agent is not polling — check the control-plane URL and
that the node is still authenticated. If it arrives and the VPS is unreachable,
the VPS is on a subnet the node itself cannot route to, which is the same
gateway question again.

**Addresses run out on one node and not another.** They cannot any more — each
node has its own `/22` and allocation is scoped to the node — but if it looks
that way, check `nodes.vps_range_start`: a node that declared its own network at
enrolment kept it, and a narrow declared range is a narrow pool.
