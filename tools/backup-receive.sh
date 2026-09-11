#!/bin/bash
# The far side of tools/backup.sh. Installed on the backup destination and wired
# into authorized_keys as a forced command:
#
#   restrict,command="/usr/local/sbin/bunk-backup-receive" ssh-ed25519 AAAA… bunk-backup
#
# That is the whole point of this file. The machine taking backups holds a key to
# the machine storing them, and if the first is compromised the second must not
# be. With a forced command the key can do exactly one thing: append a blob. It
# cannot list, read, delete or get a shell — so an attacker on the control plane
# can neither retrieve old backups nor destroy them.
#
# The blob is already encrypted to a certificate whose private key is not here
# either, so this host stores something it cannot read. That is deliberate: it
# means the destination does not have to be trusted, which is what allows the
# archive to eventually live on hardware we do not own.
set -euo pipefail

DEST="${BUNK_BACKUP_DIR:-/var/backups/bunk}"
KEEP="${BUNK_BACKUP_KEEP:-30}"
MAX_BYTES="${BUNK_BACKUP_MAX_BYTES:-2147483648}"   # 2 GiB

install -d -m 700 "$DEST"

# The client passes the filename as the (forced-away) command line. Take only a
# basename of a shape we chose, never a path: this input comes from a host we are
# defending against.
raw="${SSH_ORIGINAL_COMMAND:-}"
name="$(basename -- "$raw")"
case "$name" in
  bunk-*.tar.zst.enc) : ;;
  *) echo "refusing name: $raw" >&2; exit 2 ;;
esac
case "$name" in
  *..*|*/*) echo "refusing name: $raw" >&2; exit 2 ;;
esac

# Append-only means append-only. Without this, a key that cannot delete can
# still overwrite yesterday's backup with a byte of garbage under the same name,
# which destroys it just as thoroughly.
[ -e "$DEST/$name" ] && { echo "refusing to overwrite $name" >&2; exit 5; }

tmp="$(mktemp "$DEST/.incoming.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

# head -c bounds the write: an attacker with the key should not be able to fill
# the disk that holds every other backup.
head -c "$MAX_BYTES" > "$tmp"
size=$(stat -c %s "$tmp")
[ "$size" -gt 0 ] || { echo "empty upload" >&2; exit 3; }
[ "$size" -lt "$MAX_BYTES" ] || { echo "upload hit the $MAX_BYTES byte cap" >&2; exit 4; }

# -n: two uploads racing the same name must not both "succeed".
mv -n "$tmp" "$DEST/$name"
[ -e "$tmp" ] && { echo "refusing to overwrite $name" >&2; exit 5; }
trap - EXIT
chmod 400 "$DEST/$name"

echo "stored $name ($size bytes, sha256 $(sha256sum "$DEST/$name" | cut -c1-16)…)"

# Rotation happens here rather than on the sender, so the sender cannot be used
# to delete history.
ls -1t "$DEST"/bunk-*.tar.zst.enc 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  echo "pruning $(basename "$old")"
  rm -f -- "$old"
done
