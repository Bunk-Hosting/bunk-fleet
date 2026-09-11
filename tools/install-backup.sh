#!/bin/bash
# Set up automated backups on the control-plane host. Idempotent: re-running it
# neither rotates the encryption key nor re-authorises the SSH key.
#
#   tools/install-backup.sh                      # keys, cert, timer — no destination
#   BUNK_BACKUP_SSH=user@host tools/…            # …and point it at one
#
# Two keypairs are created, and the difference matters:
#
#   backup.crt / backup.key   Encrypts the archives. Only the .crt stays here.
#   id_ed25519                Lets this host push to the destination. The public
#                             half is authorised there behind a forced command.
#
# The private encryption key is printed once and must leave this machine. If it
# stays, an attacker who gets root here can read every backup ever taken, and a
# fire takes the key along with the thing it was protecting.
set -euo pipefail

CONF=/etc/bunk-backup
REPO="${BUNK_REPO:-/opt/bunk-fleet}"
DEST="${BUNK_BACKUP_SSH:-}"

install -d -m 700 "$CONF"

if [ ! -f "$CONF/backup.crt" ]; then
  echo "==> generating the backup encryption keypair"
  openssl req -x509 -newkey rsa:4096 -nodes -days 7300 \
    -keyout "$CONF/backup.key" -out "$CONF/backup.crt" \
    -subj "/CN=bunk-backup/O=Bunk Hosting" 2>/dev/null
  chmod 400 "$CONF/backup.key" "$CONF/backup.crt"
  NEW_KEY=1
else
  echo "==> reusing the existing backup certificate"
fi

if [ ! -f "$CONF/id_ed25519" ]; then
  echo "==> generating the push key"
  ssh-keygen -t ed25519 -N '' -C bunk-backup -f "$CONF/id_ed25519" >/dev/null
  chmod 400 "$CONF/id_ed25519"
fi

cat > /etc/systemd/system/bunk-backup.service <<UNIT
[Unit]
Description=Bunk control-plane backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=BUNK_REPO=$REPO
Environment=BUNK_BACKUP_SSH=$DEST
ExecStart=$REPO/tools/backup.sh
# A backup timer that quietly stops working is how backups actually fail.
OnFailure=bunk-backup-alert.service
UNIT

cat > /etc/systemd/system/bunk-backup-alert.service <<UNIT
[Unit]
Description=Mail the operator that the backup failed

[Service]
Type=oneshot
ExecStart=$REPO/tools/backup-alert.sh bunk-backup.service
UNIT

cat > /etc/systemd/system/bunk-backup.timer <<'UNIT'
[Unit]
Description=Bunk control-plane backup, nightly

[Timer]
# 03:17 rather than 03:00: nothing else should be running then either way, and an
# odd minute keeps it out of the pile-up every other nightly job sits in.
OnCalendar=*-*-* 03:17:00
# A machine that was off at 03:17 still owes us a backup.
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now bunk-backup.timer >/dev/null
echo "==> timer enabled: $(systemctl show -p NextElapseUSecRealtime --value bunk-backup.timer)"

echo
if [ -z "$(grep -s '^OPS_EMAIL=' "$REPO/.env.prod")" ]; then
  echo
  echo "NOTE: OPS_EMAIL is not set in $REPO/.env.prod, so a failed backup will"
  echo "      have nowhere to report to. Add it and redeploy the control plane."
fi

echo
echo "Authorise this host at the destination by adding to its authorized_keys:"
echo
echo "  restrict,command=\"/usr/local/sbin/bunk-backup-receive\" $(cat "$CONF/id_ed25519.pub")"
echo

if [ "${NEW_KEY:-}" = "1" ]; then
  echo "=============================================================="
  echo " The backup decryption key is at $CONF/backup.key"
  echo
  echo " MOVE IT OFF THIS MACHINE. Nothing here can read a backup"
  echo " without it, which is the point — and nothing anywhere can,"
  echo " if it is lost with the machine it was protecting."
  echo "=============================================================="
fi
