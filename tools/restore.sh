#!/bin/bash
# Restore from an encrypted backup. Runs wherever the private key is — which is
# deliberately NOT the machine that takes the backups.
#
#   tools/restore.sh --inspect  bunk-….tar.zst.enc          # what is in it
#   tools/restore.sh --extract  bunk-….tar.zst.enc DIR      # unpack, restore nothing
#   tools/restore.sh --into-db  bunk-….tar.zst.enc DBNAME   # rehearse or recover
#
# --into-db refuses to write to the live database. Recovering onto the real name
# is a deliberate act with the service stopped, not something a script should do
# because an argument was mistyped.
set -euo pipefail

KEY="${BUNK_BACKUP_KEY:-/root/bunk-backup.key}"
PG_CONTAINER="${BUNK_PG_CONTAINER:-bf-prod-pg}"
DB_USER="${BUNK_DB_USER:-bunkfleet}"
LIVE_DB="${BUNK_LIVE_DB:-control_plane}"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
fail() { echo "FAILED: $*" >&2; exit 1; }

mode="${1:-}"; archive="${2:-}"; target="${3:-}"
[ -n "$mode" ] && [ -n "$archive" ] || usage
[ -r "$archive" ] || fail "cannot read $archive"
[ -r "$KEY" ] || fail "no private key at $KEY (set BUNK_BACKUP_KEY)"

work="$(mktemp -d)"; chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

openssl smime -decrypt -binary -inform DER -in "$archive" -inkey "$KEY" \
  | zstd -dq \
  | tar -C "$work" -xf - \
  || fail "decrypt failed — wrong key, or the archive is damaged"

[ -s "$work/manifest" ] || fail "no manifest in the archive"
[ -s "$work/db.dump" ] || fail "no database dump in the archive"

# The manifest records what the dump was when it was taken; checking it here is
# what separates "a file exists" from "a backup exists".
recorded="$(grep '^db_dump_sha256=' "$work/manifest" | cut -d= -f2)"
actual="$(sha256sum "$work/db.dump" | cut -d' ' -f1)"
[ "$recorded" = "$actual" ] || fail "dump checksum mismatch: recorded $recorded, got $actual"

case "$mode" in
  --inspect)
    cat "$work/manifest"
    echo "integrity=ok"
    ;;

  --extract)
    [ -n "$target" ] || usage
    install -d -m 700 "$target"
    cp "$work/manifest" "$work/db.dump" "$work/env.prod" "$target/"
    echo "extracted to $target (env.prod holds live secrets — treat it as such)"
    ;;

  --into-db)
    [ -n "$target" ] || usage
    [ "$target" != "$LIVE_DB" ] || fail "refusing to restore onto the live database ($LIVE_DB)"

    echo "restoring into $target"
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$target\"" -c "CREATE DATABASE \"$target\"" >/dev/null \
      || fail "could not recreate $target"

    docker exec -i "$PG_CONTAINER" pg_restore -U "$DB_USER" -d "$target" --no-owner \
      < "$work/db.dump" || fail "pg_restore failed"

    # A restore that produced an empty schema is a failure that exits 0 without
    # this check.
    users=$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$target" -tAc 'select count(*) from users')
    vpses=$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$target" -tAc 'select count(*) from vpses')
    ledger=$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$target" -tAc 'select coalesce(sum(amount_cents),0) from ledger_entries')
    migration=$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$target" -tAc 'select max(version) from schema_migrations')

    echo "restored: users=$users vpses=$vpses ledger_cents=$ledger schema=$migration"
    grep '^schema_migration=' "$work/manifest"
    ;;

  *) usage ;;
esac
