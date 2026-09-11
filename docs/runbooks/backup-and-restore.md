# Runbook — backup and restore

Until this existed there was no backup. A `pg_dump` taken by hand during a
migration sat on the same VM as the database it came from, which protects
against nothing that actually happens.

## What is protected, and what is not

**Protected:** the control plane — customers, wallets, the ledger, VPS
inventory, node identities — and the secrets in `.env.prod`, which matter
independently: they carry `CONSOLE_SSH_PRIVATE_KEY`, and without it a restored
database describes VPSes nobody can get into any more.

**Not protected:** customer VPS disks. If a node's storage dies, the data on it
is gone. That is a per-node job (`vzdump` and somewhere to put it) and it is not
built yet. Say so honestly to anyone asking what they are buying.

## How it works

Nightly at 03:17 (`bunk-backup.timer`), `tools/backup.sh`:

1. `pg_dump -Fc` the control-plane database, out of the Postgres container.
2. Copy `.env.prod`.
3. Write a manifest — timestamp, git commit, schema migration, dump checksum.
4. tar → zstd → `openssl smime -encrypt` to a certificate.
5. Push over SSH to the destination and prune the local staging copy.

If any of that fails, systemd runs `tools/backup-alert.sh`, which mails the
address in `OPS_EMAIL` through the control plane's own relay — the same one that
sends confirmation emails, so there is no second thing to keep working. A backup
timer that quietly stops is how backups actually fail; nobody finds out until the
day they are needed.

Two keypairs, and the split is the design:

| | lives on | if it leaks |
|---|---|---|
| `backup.crt` (encrypt) | the control-plane host | nothing: it only encrypts |
| `backup.key` (decrypt) | **off the machine** | every backup is readable |
| `id_ed25519` (push) | the control-plane host | nothing useful: forced command |

The destination runs `tools/backup-receive.sh` as a forced command, so the key
the control plane holds can do exactly one thing — append a blob. It cannot
list, read or delete. An attacker who takes the control plane can therefore
neither retrieve the history nor destroy it, and the destination stores
something it cannot read. That last property is what will let the archive
eventually live on hardware we do not own.

## Setting it up

On the destination:

```bash
useradd -m -d /var/lib/bunkbackup -s /bin/bash bunkbackup
install -m 755 tools/backup-receive.sh /usr/local/sbin/bunk-backup-receive
install -d -m 700 -o bunkbackup -g bunkbackup /var/backups/bunk
# then add the line install-backup.sh prints to
# /var/lib/bunkbackup/.ssh/authorized_keys
```

On the control-plane host:

```bash
BUNK_BACKUP_SSH=bunkbackup@<destination> tools/install-backup.sh
```

It generates both keypairs (reusing any that exist), writes the service and
timer, and prints the `authorized_keys` line. **Then move `backup.key` off the
machine** — a password manager, not another server in the same rack. Everything
else here is rebuildable; that file is not.

## Restoring

Run `tools/restore.sh` wherever the private key is.

```bash
tools/restore.sh --inspect bunk-….tar.zst.enc              # when, which commit, which schema
tools/restore.sh --extract bunk-….tar.zst.enc /tmp/r       # unpack; restores nothing
tools/restore.sh --into-db bunk-….tar.zst.enc control_plane_rehearsal
```

Every mode verifies the dump against the checksum in the manifest before doing
anything, so "the file is there" and "the backup is good" are not confused.

`--into-db` refuses the live database name. Recovering for real means stopping
the control plane and restoring deliberately, not mistyping an argument:

```bash
docker stop bf-prod-cp
docker exec bf-prod-pg psql -U bunkfleet -d postgres \
  -c 'ALTER DATABASE control_plane RENAME TO control_plane_broken'
BUNK_LIVE_DB=none tools/restore.sh --into-db bunk-….tar.zst.enc control_plane
# put env.prod back from the archive if the secrets were lost too
docker start bf-prod-cp
```

Rename rather than drop. The database you are replacing is the only evidence of
what went wrong, and disk is cheaper than that.

## Rehearsals

An untested restore is a hope, not an RTO. Rehearse into a scratch database
after any migration that changes shape, and write down what it cost.

| date | archive | restored | wall clock | notes |
|---|---|---|---|---|
| 2026-09-11 | `bunk-20260911T181736Z` (23.9 kB) | users 3, vpses 6, ledger 3903c, schema 20260911090000 — all matching live | **21 s** (backup itself: 1 s) | rehearsed on the control-plane host |

Those counts were compared against the live database, not just read back out of
the thing that produced them.

The 21 seconds is decrypt + `pg_restore` on a database this size. It will grow
roughly with the data and is not the number that matters for an outage: the
recovery path above also stops the service and needs someone to notice. Treat it
as the floor, not the RTO.

One gap, deliberately left visible: this rehearsal ran on the machine the backup
came from, so it proves the archive is complete and restorable — not that
recovery works with that machine gone. The next one should restore somewhere
else, which also forces the question of whether `backup.key` is genuinely
reachable from somewhere else.
