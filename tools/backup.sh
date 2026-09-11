#!/bin/bash
# Take one encrypted backup of everything needed to rebuild the control plane,
# and push it off this machine.
#
# What is in it, and why each part:
#   db.dump      pg_dump -Fc of control_plane. Customers, wallets, ledger, VPS
#                inventory, node identities. Losing this loses who owns what.
#   env.prod     The secrets file. It carries CONSOLE_SSH_PRIVATE_KEY, and
#                without that there is no way back into any existing customer
#                VPS — a database restore alone would leave every machine we
#                already provisioned unreachable.
#   manifest     What this backup is: when, which commit, which migration the
#                schema is at. A restore that silently targets the wrong schema
#                version is worse than no restore.
#
# Encryption is asymmetric on purpose: only the certificate lives here. A
# compromise of this VM cannot read yesterday's backup, and the destination does
# not have to be trusted — which is what makes it possible to later push these
# to a node we do not own.
#
#   tools/backup.sh                 # take one, push it, prune
#   BUNK_BACKUP_DRY_RUN=1 …         # build and encrypt, do not push
set -euo pipefail

REPO="${BUNK_REPO:-/opt/bunk-fleet}"
ENV_FILE="${BUNK_ENV_FILE:-$REPO/.env.prod}"
CERT="${BUNK_BACKUP_CERT:-/etc/bunk-backup/backup.crt}"
SPOOL="${BUNK_BACKUP_SPOOL:-/var/backups/bunk}"
PG_CONTAINER="${BUNK_PG_CONTAINER:-bf-prod-pg}"
DB_NAME="${BUNK_DB_NAME:-control_plane}"
DB_USER="${BUNK_DB_USER:-bunkfleet}"
# Where to push. Empty means local-only, which is not a backup — the script says
# so loudly rather than exiting 0 and letting a timer report success forever.
DEST="${BUNK_BACKUP_SSH:-}"
SSH_KEY="${BUNK_BACKUP_SSH_KEY:-/etc/bunk-backup/id_ed25519}"
KEEP="${BUNK_BACKUP_KEEP:-14}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "FAILED: $*" >&2; exit 1; }

[ -r "$CERT" ] || fail "no backup certificate at $CERT — run tools/install-backup.sh first"
[ -r "$ENV_FILE" ] || fail "cannot read $ENV_FILE"
command -v zstd >/dev/null || fail "zstd is not installed"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

log "dumping $DB_NAME"
# -Fc (custom): compressed, and pg_restore can select out of it. Dumped through
# the container so this needs no client version matching the server.
docker exec "$PG_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$work/db.dump" \
  || fail "pg_dump failed"
[ -s "$work/db.dump" ] || fail "pg_dump produced an empty file"

cp "$ENV_FILE" "$work/env.prod"

migration="$(docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
  'select max(version) from schema_migrations' 2>/dev/null || echo unknown)"
commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$work/manifest" <<MANIFEST
taken_at=$stamp
host=$(hostname)
git_commit=$commit
schema_migration=$migration
db_dump_bytes=$(stat -c %s "$work/db.dump")
db_dump_sha256=$(sha256sum "$work/db.dump" | cut -d' ' -f1)
env_sha256=$(sha256sum "$work/env.prod" | cut -d' ' -f1)
MANIFEST

out="$SPOOL/bunk-$stamp.tar.zst.enc"
install -d -m 700 "$SPOOL"

log "encrypting to $out"
tar -C "$work" -cf - manifest db.dump env.prod \
  | zstd -q -T0 -3 \
  | openssl smime -encrypt -binary -aes-256-cbc -outform DER -out "$out" "$CERT" \
  || fail "encrypt failed"
chmod 600 "$out"

size=$(stat -c %s "$out")
sha=$(sha256sum "$out" | cut -d' ' -f1)
log "wrote $out ($size bytes, sha256 ${sha:0:16}…, schema $migration, commit $commit)"

if [ -n "${BUNK_BACKUP_DRY_RUN:-}" ]; then
  log "dry run: not pushing"
  exit 0
fi

if [ -z "$DEST" ]; then
  log "WARNING: BUNK_BACKUP_SSH is not set. This copy is on the same machine as" >&2
  log "         the thing it is backing up, which protects against nothing that" >&2
  log "         actually happens. Configure a destination." >&2
  exit 1
fi

[ -r "$SSH_KEY" ] || fail "no ssh key at $SSH_KEY"
log "pushing to $DEST"
# The far side runs a forced command that only accepts a blob on stdin, so this
# key cannot be used for anything else if this VM is compromised.
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 "$DEST" "bunk-$stamp.tar.zst.enc" < "$out" \
  || fail "push to $DEST failed"
log "pushed"

# Local spool is a staging area, not the archive: keep a few, let the far side
# hold the history.
ls -1t "$SPOOL"/bunk-*.tar.zst.enc 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  log "pruning $old"
  rm -f -- "$old"
done

log "ok"
